@_spi(Testing) import DashKit
import Foundation

/// Proves that Dashii's and agents' tools read Dash's database and never a service: every request
/// made while it records is blocked and reported. It sees requests through `HTTP.send` and
/// `IntegrationConnection.send` (custom transports such as Docker's socket included) for the
/// recording task, and through `URLSession.shared` (a URLProtocol, while any recording runs).
///
/// ```swift
/// #expect(await NetworkSentinel.requests(running: integration.tools, values: ["repo": "acme/billing-api"]) == [])
/// ```
public enum NetworkSentinel {
    /// Runs `body`, blocking and recording every request it makes: "GET host/path" (no query).
    @MainActor
    public static func recording<T>(_ body: () async throws -> T) async rethrows -> (T, [String]) {
        let log = RequestLog()
        SentinelProtocol.add(log)
        defer { SentinelProtocol.remove(log) }
        let result = try await NetworkObserver.$observe.withValue({ request in
            let line = describe(request)
            log.append(line)
            throw NetworkBlocked(request: line)
        }) {
            try await body()
        }
        return (result, log.lines)
    }

    /// Runs every tool Dash may give Dashii or an agent (not `writesRemotely`, not `callsService`)
    /// with a minimal input built from its schema, and returns "tool: GET host/path" for each
    /// request one made: empty when they all read the database. `values` fills properties by name
    /// wherever they appear (`"repo": "acme/billing-api"`); `inputs` replaces a tool's whole input.
    @MainActor
    public static func requests(running tools: [DashiiTool], values: [String: JSONValue] = [:], inputs: [String: JSONValue] = [:]) async -> [String] {
        var found: [String] = []
        for tool in tools where tool.isForDashii {
            let input = inputs[tool.name] ?? minimalInput(tool.inputSchema, values: values)
            let (_, requests) = await recording { _ = try? await tool.run(input) }
            found += requests.map { "\(tool.name): \($0)" }
        }
        return found
    }

    /// The required properties of a tool's input schema with placeholder values (the first enum
    /// value, "x", 1, false, [], {}), plus any property named in `values`.
    public static func minimalInput(_ schema: JSONValue, values: [String: JSONValue] = [:]) -> JSONValue {
        let required = Set((schema["required"]?.array ?? []).compactMap(\.string))
        var input: [String: JSONValue] = [:]
        for (name, property) in schema["properties"]?.object ?? [:] {
            if let value = values[name] {
                input[name] = value
            } else if required.contains(name) {
                input[name] = placeholder(property)
            }
        }
        return .object(input)
    }

    private static func placeholder(_ property: JSONValue) -> JSONValue {
        if let first = property["enum"]?.array?.first { return first }
        switch property["type"]?.string {
        case "integer", "number": return 1
        case "boolean": return false
        case "array": return []
        case "object": return [:]
        default: return "x"
        }
    }

    static func describe(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "GET") \(request.url?.host() ?? "?")\(request.url?.path() ?? "")"
    }
}

/// The error a blocked request fails with.
public struct NetworkBlocked: LocalizedError, Equatable {
    public let request: String
    public var errorDescription: String? { "NetworkSentinel blocked \(request): tools read Dash's database; fetchers call services." }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ line: String) { lock.withLock { entries.append(line) } }
    var lines: [String] { lock.withLock { entries } }
}

/// Blocks and records `URLSession.shared` requests while a recording runs.
final class SentinelProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var logs: [ObjectIdentifier: RequestLog] = [:]

    static func add(_ log: RequestLog) {
        let first = lock.withLock {
            logs[ObjectIdentifier(log)] = log
            return logs.count == 1
        }
        if first { URLProtocol.registerClass(SentinelProtocol.self) }
    }

    static func remove(_ log: RequestLog) {
        let last = lock.withLock {
            logs[ObjectIdentifier(log)] = nil
            return logs.isEmpty
        }
        if last { URLProtocol.unregisterClass(SentinelProtocol.self) }
    }

    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { !logs.isEmpty } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let line = NetworkSentinel.describe(request)
        for log in Self.lock.withLock({ Array(Self.logs.values) }) { log.append(line) }
        client?.urlProtocol(self, didFailWithError: NetworkBlocked(request: line))
    }

    override func stopLoading() {}
}
