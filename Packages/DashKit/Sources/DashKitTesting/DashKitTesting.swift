import DashKit
import Foundation
import SwiftData

/// Problems with what an extension hands to the knowledge graph: ids that aren't
/// "<kind>:<key>" or don't start with their kind, duplicates, and links nowhere.
public func knowledgeIssues(_ entities: [KnowledgeEntity]) -> [String] {
    var issues: [String] = []
    var seen = Set<String>()
    for entity in entities {
        if !entity.id.hasPrefix(entity.kind + ":") || entity.id.count <= entity.kind.count + 1 {
            issues.append("\(entity.id): id should be \"\(entity.kind):<key>\"")
        }
        if !seen.insert(entity.id).inserted { issues.append("\(entity.id): handed in twice") }
        if entity.title.isEmpty { issues.append("\(entity.id): empty title") }
        for link in entity.links where !link.to.contains(":") || link.to.hasSuffix(":") || link.kind.isEmpty {
            issues.append("\(entity.id): bad link \(link.kind) → \(link.to)")
        }
    }
    return issues
}

// Test doubles for plugin authors: a host, Claude, permissions, an integration, and HTTP stubs,
// so a plugin's tests exercise it the way Dash will, without the app, the network or a login.
// Link it from test targets only.

/// An `ExtensionContext` with an in-memory store, recording what the extension asks of Dash.
@MainActor
public final class TestHost: ExtensionContext, @unchecked Sendable {
    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }
    public var extensions: [any DashExtension]
    public let testPermissions = TestPermissions()
    public let testClaude = TestClaude()
    public var permissions: any PermissionAsking { testPermissions }
    public var claude: any ClaudeService { testClaude }
    public let activity = ActivityLog()
    /// Extension ids treated as turned off.
    public var disabled: Set<String> = []
    /// AI choices per scope, as the user would set them in an AI tab.
    public var aiChoices: [AIScope: [String: AITaskChoice]] = [:]

    public private(set) var askedClaude: [String] = []
    public private(set) var openedManager: [String?] = []
    public private(set) var addedWidgets: [String] = []
    /// Notes written with `createNote` (title, markdown, folder).
    public private(set) var notes: [(title: String, markdown: String, folder: String?)] = []

    /// `models`: the SwiftData models the extensions under test persist.
    public init(_ extensions: [any DashExtension] = [], models: [any PersistentModel.Type] = []) throws {
        let schema = Schema(models + extensions.flatMap(\.models))
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        self.extensions = extensions
    }

    public func isEnabled(_ item: any DashExtension) -> Bool { !disabled.contains(item.id) }
    public func askClaude(_ prompt: String) { askedClaude.append(prompt) }
    public func openManager(_ extensionID: String?) { openedManager.append(extensionID) }
    public func addWidget(kind: String) throws { addedWidgets.append(kind) }

    public func createNote(title: String, markdown: String, folder: String?) throws -> URL {
        notes.append((title, markdown, folder))
        return FileManager.default.temporaryDirectory.appending(path: "\(title).md")
    }
    public func aiSettings(_ scope: AIScope, tasks: [AITask]) -> AISettings {
        AISettings(tasks: tasks, choices: aiChoices[scope] ?? [:], scope: scope)
    }
    public func setAIChoice(_ choice: AITaskChoice?, task: String, scope: AIScope) {
        aiChoices[scope, default: [:]][task] = choice
    }

    /// Reports of agents run with `runAgent`, newest first, by "<extension id>.<agent id>".
    public private(set) var reports: [String: [AgentReport]] = [:]

    /// Runs an agent like Dash does: its precheck, then (unless skipped) `testClaude` with the
    /// report schema. Queue the report JSON in `testClaude.replies` to test what it finds.
    public func runAgent(_ id: String, reason: String) async throws -> AgentReport {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let owner = extensions.first(where: { $0.id == parts[0] }),
              let agent = owner.agents.first(where: { $0.id == parts[1] }) else { throw ToolError("No agent \(id).") }
        let started = Date()
        var context = ""
        if let precheck = agent.precheck {
            switch await precheck(self) {
            case .skip(let note):
                let report = AgentReport(agentID: id, startedAt: started, reason: reason, status: .skipped, summary: note)
                reports[id, default: []].insert(report, at: 0)
                return report
            case .run(let seen):
                context = seen
            @unknown default:
                break
            }
        }
        let report: AgentReport
        do {
            let text = try await testClaude.complete(system: agent.systemPrompt, prompt: "Reason: \(reason)\n\(context)",
                                                     outputSchema: AgentReport.outputSchema, effort: nil, model: nil,
                                                     source: "agent.\(id)")
            report = try AgentReport.parse(text, agentID: id, startedAt: started, reason: reason)
        } catch {
            report = AgentReport(agentID: id, startedAt: started, reason: reason, status: .failed, summary: error.localizedDescription)
        }
        reports[id, default: []].insert(report, at: 0)
        return report
    }

    public func agentReports(_ id: String, limit: Int) -> [AgentReport] { Array((reports[id] ?? []).prefix(limit)) }

    /// Starts an extension against this host (integrations first when given several).
    public func start(_ items: [any DashExtension]) {
        for item in items where !extensions.contains(where: { $0 === item }) { extensions.append(item) }
        for item in items.filter({ $0.layer == .integration }) + items.filter({ $0.layer == .feature }) { item.start(host: self) }
    }

    /// Runs one of the installed extensions' Claude tools by name.
    public func runTool(_ name: String, _ input: JSONValue = [:]) async throws -> JSONValue? {
        guard let tool = extensions.lazy.flatMap(\.tools).first(where: { $0.name == name }) else {
            throw ToolError("No tool named \(name).")
        }
        return try await tool.run(input)
    }
}

/// Claude for tests: returns queued replies (or `reply`) and records every request.
@MainActor
public final class TestClaude: ClaudeService {
    public struct Call: Sendable {
        public let system: String
        public let prompt: String
        public let outputSchema: JSONValue?
        public let effort: String?
        public let model: String?
        public let source: String?
    }

    public var model = "claude-test"
    /// Returned when `replies` is empty.
    public var reply = ""
    /// Returned in order, one per call.
    public var replies: [String] = []
    public var error: (any Error)?
    public private(set) var calls: [Call] = []

    public init() {}

    public func complete(system: String, prompt: String, outputSchema: JSONValue?, effort: String?) async throws -> String {
        try await complete(system: system, prompt: prompt, outputSchema: outputSchema, effort: effort, model: nil)
    }

    public func complete(system: String, prompt: String, outputSchema: JSONValue?, effort: String?, model: String?) async throws -> String {
        try await complete(system: system, prompt: prompt, outputSchema: outputSchema, effort: effort, model: model, source: nil)
    }

    public func complete(system: String, prompt: String, outputSchema: JSONValue?, effort: String?, model: String?, source: String?) async throws -> String {
        calls.append(Call(system: system, prompt: prompt, outputSchema: outputSchema, effort: effort, model: model, source: source))
        if let error { throw error }
        return replies.isEmpty ? reply : replies.removeFirst()
    }
}

/// Permission prompts for tests: answers with `answer` and records what was asked.
@MainActor
public final class TestPermissions: PermissionAsking {
    public var answer = false
    public private(set) var asked: [String] = []

    public init() {}

    public func ask(icon: String, title: String, message: String, details: [PermissionDetail], allowLabel: String, denyLabel: String) async -> Bool {
        asked.append(title)
        return answer
    }
}

/// An integration stand-in: a connection to a stubbed host plus the exports features read.
@MainActor
public final class TestIntegration: Integration {
    public let id: String
    public let name: String
    public let systemImage = "testtube.2"
    public var layer: ExtensionLayer { .integration }
    public var isConnected: Bool
    public var exports: JSONValue
    public var testConnection: IntegrationConnection

    public var connection: IntegrationConnection? { isConnected ? testConnection : nil }

    /// `baseURL` is usually a host registered with `StubHTTP`; requests go through its session.
    public init(id: String, baseURL: URL, headers: [String: String] = [:], exports: JSONValue = [:], connected: Bool = true) {
        self.id = id
        self.name = id.capitalized
        self.exports = exports
        self.isConnected = connected
        testConnection = IntegrationConnection(baseURL: baseURL, headers: headers, session: StubHTTP.session)
    }
}

/// Canned HTTP responses per host, for URLSessions built with `StubHTTP.session` (or
/// `configuration`). Each test should use its own host name so parallel tests don't collide.
public final class StubHTTP: URLProtocol, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data, headers: [String: String])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]

    public static func serve(_ host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            log[host] = []
        }
    }

    /// Every request to `host` gets this JSON (or text) body.
    public static func serve(_ host: String, json: String, status: Int = 200, headers: [String: String] = [:]) {
        serve(host) { _ in (status, Data(json.utf8), headers) }
    }

    /// Requests to `host` by path (with query); unknown paths get a 404.
    public static func serve(_ host: String, routes: [String: String]) {
        serve(host) { request in
            let path = request.url.map { $0.path() + ($0.query().map { "?\($0)" } ?? "") } ?? ""
            guard let body = routes[path] ?? routes[request.url?.path() ?? ""] else { return (404, Data("no route \(path)".utf8), [:]) }
            return (200, Data(body.utf8), [:])
        }
    }

    public static func requests(_ host: String) -> [URLRequest] { lock.withLock { log[host] ?? [] } }

    public static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return configuration
    }

    public static let session = URLSession(configuration: configuration)

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let host = request.url?.host() ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log[host, default: []].append(request)
            return Self.handlers[host]
        }
        let (status, body, headers) = handler?(request) ?? (599, Data("no stub for \(host)".utf8), [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}
}
