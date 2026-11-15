import DashKitUI
import Foundation
import SwiftData
import SwiftUI

/// A module of Dash: built in, declared in a `.dashext` manifest, or loaded from a `.dashplugin`.
/// An extension contributes any mix of dashboard widgets, Dashii tools, SwiftData models,
/// background work and a settings pane.
@MainActor
public protocol DashExtension: AnyObject {
    var id: String { get }
    var name: String { get }
    var systemImage: String { get }
    var layer: ExtensionLayer { get }
    /// Version, owner, summary, category, links.
    var metadata: ExtensionMetadata { get }
    /// Integration ids this extension needs. Its tools are hidden from Dashii until all are connected.
    var requires: [String] { get }
    /// Integrations that add capabilities when connected but aren't needed.
    var optional: [String] { get }

    /// SwiftData models it persists; they join the app-wide store (known at launch).
    var models: [any PersistentModel.Type] { get }
    /// Keychain items it keeps (shown, and removable, in Settings).
    var secretKeys: [SecretKey] { get }
    var secrets: SecretStore? { get }
    /// Prefix of its UserDefaults keys ("<prefix>.<name>").
    var storagePrefix: String { get }
    var widgets: [WidgetType] { get }
    var tools: [DashiiTool] { get }
    /// What DashQL can read from this extension (pods, tickets, PRs…). Read-only.
    var datasets: [QueryDataset] { get }
    /// Ready-made hooks for this extension's data: watchers, notifications, agent wake-ups.
    var hookPresets: [HookPresetSpec] { get }
    /// What its background work asks Claude to do (e.g. automatic PR reviews), configurable in
    /// the extension's AI settings (`host.aiSettings(.extension(id), tasks: aiTasks)`).
    var aiTasks: [AITask] { get }
    /// What it proposes on the Home page right now (things waiting for the user). Keep it cheap:
    /// read from state the extension already has; Dash asks often.
    var suggestions: [Suggestion] { get }
    /// Components notes can use (`@JiraIssue(key: "PROJ-12")`).
    var components: [MarkdownComponentType] { get }
    /// Instructions Dashii follows whenever this extension's tools or AI tasks are used; the
    /// user can edit them (Settings › Automation › Rules).
    var defaultRules: String? { get }
    /// `/commands` it offers; the user can customize them.
    var defaultCommands: [CommandDefinition] { get }
    /// The activity events it emits, for the user's hooks.
    var events: [EventDefinition] { get }
    /// What it knows (tickets, PRs, sessions…) for Dash's knowledge graph. Read from stored data;
    /// Dash asks after each sync cycle.
    var knowledge: [KnowledgeEntity] { get }
    /// Background agents it offers (an SRE watching clusters, a triager…). See `AgentDefinition`.
    var agents: [AgentDefinition] { get }
    /// Counts per day it can chart (the Activity Heatmap widget). See `ActivitySeries`.
    var activitySeries: [ActivitySeries] { get }

    func settingsView() -> AnyView
    /// Called once the store exists (and again when re-enabled). Start polling or observers here.
    func start(host: any ExtensionContext)
    /// Awaited during launch, after `start`, while the splash screen shows progress: verify
    /// credentials (integrations) or do the first sync (features). Keep it bounded; Dash times out.
    func prepare(host: any ExtensionContext) async throws
    func stop()
}

extension DashExtension {
    public var layer: ExtensionLayer { .feature }
    public var metadata: ExtensionMetadata { ExtensionMetadata() }
    public var requires: [String] { [] }
    public var optional: [String] { [] }
    public var models: [any PersistentModel.Type] { [] }
    public var aiTasks: [AITask] { [] }
    public var suggestions: [Suggestion] { [] }
    public var components: [MarkdownComponentType] { [] }
    public var defaultRules: String? { nil }
    public var defaultCommands: [CommandDefinition] { [] }
    public var events: [EventDefinition] { [] }
    public var knowledge: [KnowledgeEntity] { [] }
    public var agents: [AgentDefinition] { [] }
    public var activitySeries: [ActivitySeries] { [] }
    public var secretKeys: [SecretKey] { [] }
    public var secrets: SecretStore? { secretKeys.isEmpty ? nil : SecretStore(extensionID: id) }
    public var storagePrefix: String { id }
    public var widgets: [WidgetType] { [] }
    public var datasets: [QueryDataset] { [] }
    public var hookPresets: [HookPresetSpec] { [] }
    public var tools: [DashiiTool] { [] }
    public func settingsView() -> AnyView { AnyView(EmptyView()) }
    public func start(host: any ExtensionContext) {}
    public func prepare(host: any ExtensionContext) async throws {}
    public func stop() {}

    public var author: ExtensionAuthor { metadata.author }
    public var summary: String { metadata.summary }
    public var preferences: PreferenceStore { PreferenceStore(prefix: storagePrefix) }
}

/// How features reach a connected account. Features (including declarative and plugin ones)
/// send requests through it without ever seeing the secret.
public struct IntegrationConnection: Sendable {
    /// Requests by `path` are joined onto this URL.
    public let baseURL: URL
    /// Static auth headers (token-based accounts).
    public var headers: [String: String]
    /// Extra host suffixes full-`url` requests may target (".googleapis.com", ".amazonaws.com").
    public var hosts: [String]
    /// Per-request signing for credentials that change (fresh OAuth tokens, AWS SigV4).
    public var sign: (@Sendable (URLRequest) async throws -> URLRequest)?
    /// A session with custom trust (a cluster's own CA, client certificates). Default: shared.
    public var session: URLSession?
    /// A custom transport for endpoints URLSession can't reach (Docker's unix socket).
    public var transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?

    public init(
        baseURL: URL, headers: [String: String] = [:], hosts: [String] = [],
        sign: (@Sendable (URLRequest) async throws -> URLRequest)? = nil, session: URLSession? = nil,
        transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.baseURL = baseURL
        self.headers = headers
        self.hosts = hosts
        self.sign = sign
        self.session = session
        self.transport = transport
    }

    /// Authorizes and sends a request; non-2xx responses (except 304) throw `HTTPError`.
    public func send(_ request: URLRequest, service: String) async throws -> (Data, HTTPURLResponse) {
        let authorized = try await authorize(request)
        if let transport {
            let (data, response) = try await transport(authorized)
            try HTTP.check(data, response, service: service)
            return (data, response)
        }
        return try await HTTP.send(authorized, service: service, session: session ?? .shared)
    }

    /// GET a path (with optional query) and parse JSON.
    public func get(_ path: String, service: String) async throws -> JSONValue {
        guard let url = url(path) else { throw ToolError("Bad path \(path)") }
        let (data, _) = try await send(URLRequest(url: url), service: service)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    /// Joins a path ("/repos/x/y") onto the base URL.
    public func url(_ path: String) -> URL? {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// True if a full URL stays on this account's hosts.
    public func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host() else { return false }
        // "googleapis.com" allows googleapis.com and its subdomains, never "evilgoogleapis.com".
        return host == baseURL.host() || hosts.contains { allowed in
            let domain = allowed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// Adds headers and signs: what every request through this connection goes through.
    public func authorize(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        for (name, value) in headers where request.value(forHTTPHeaderField: name) == nil { request.setValue(value, forHTTPHeaderField: name) }
        return try await sign?(request) ?? request
    }
}

/// Layer 1: an account and its connection.
@MainActor
public protocol Integration: DashExtension {
    /// Credentials present and accepted (as far as the integration knows).
    var isConnected: Bool { get }
    /// Status shown in Settings: account name, checking, or the last error.
    var connectionState: ConnectionState { get }
    var connection: IntegrationConnection? { get }
    /// Non-secret config features may read (watched repos, signed-in login, site URL…).
    var exports: JSONValue { get }
}

extension Integration {
    public var layer: ExtensionLayer { .integration }
    public var connectionState: ConnectionState { isConnected ? .connected(nil) : .notConfigured }
    public var exports: JSONValue { .object([:]) }

    /// The usual mapping: an error wins, then "no credentials", then the signed-in account.
    public func state(error: String?, configured: Bool, account: String?) -> ConnectionState {
        if let error { return .failed(error) }
        if !configured { return .notConfigured }
        return account.map { .connected("Signed in as \($0)") } ?? .connected(nil)
    }
}

// MARK: - What the host gives extensions

/// One line of a permission prompt.
public struct PermissionDetail: Hashable, Sendable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// A permission prompt: what's asked, why, and the button labels.
public struct PermissionPrompt: Sendable, Equatable {
    public var icon: String
    public var title: String
    public var message: String
    public var details: [PermissionDetail]
    public var allowLabel: String
    public var denyLabel: String

    public init(icon: String = "hand.raised", title: String, message: String, details: [PermissionDetail] = [],
                allowLabel: String = "Allow", denyLabel: String = "Don't Allow") {
        self.icon = icon
        self.title = title
        self.message = message
        self.details = details
        self.allowLabel = allowLabel
        self.denyLabel = denyLabel
    }
}

/// Shows a modal permission prompt and returns whether the user allowed it.
@MainActor
public protocol PermissionAsking: AnyObject {
    func ask(_ prompt: PermissionPrompt) async -> Bool
}

extension PermissionAsking {
    /// The same, with the prompt's parts as arguments.
    public func ask(icon: String = "hand.raised", title: String, message: String, details: [PermissionDetail] = [],
                    allowLabel: String = "Allow", denyLabel: String = "Don't Allow") async -> Bool {
        await ask(PermissionPrompt(icon: icon, title: title, message: message, details: details, allowLabel: allowLabel, denyLabel: denyLabel))
    }
}

/// One request to Dashii.
public struct DashiiRequest: Sendable, Equatable {
    public var system: String
    public var prompt: String
    /// A JSON schema the answer must follow (the answer is then JSON text).
    public var outputSchema: JSONValue?
    /// A `DashiiEffort` raw value; nil uses the app's.
    public var effort: String?
    /// A `DashiiModel` raw value; nil uses the app's.
    public var model: String?
    /// Who's asking ("extension.pull-requests/review"), for usage analytics.
    public var source: String?

    public init(system: String, prompt: String, outputSchema: JSONValue? = nil, effort: String? = nil, model: String? = nil, source: String? = nil) {
        self.system = system
        self.prompt = prompt
        self.outputSchema = outputSchema
        self.effort = effort
        self.model = model
        self.source = source
    }
}

/// Dashii, the app's assistant, as the host has it set up. One requirement: new options arrive as
/// `DashiiRequest` fields, never as new requirements.
@MainActor
public protocol DashiiService {
    /// The model the app uses by default (a `DashiiModel` raw value).
    var model: String { get }
    /// Answers one request: the text, or JSON text matching `outputSchema` when given.
    func complete(_ request: DashiiRequest) async throws -> String
}

extension DashiiService {
    /// The same, with the request's parts as arguments.
    public func complete(system: String, prompt: String, outputSchema: JSONValue? = nil, effort: String? = nil,
                         model: String? = nil, source: String? = nil) async throws -> String {
        try await complete(DashiiRequest(system: system, prompt: prompt, outputSchema: outputSchema, effort: effort, model: model, source: source))
    }

    /// Structured output decoded into `T`.
    public func complete<T: Decodable>(_ type: T.Type, system: String, prompt: String, schema: JSONValue, effort: String? = nil) async throws -> T {
        try JSONValue.parse(try await complete(system: system, prompt: prompt, outputSchema: schema, effort: effort)).decode(T.self)
    }
}

/// The host an extension runs in: storage, other extensions, permissions, Dashii and activity.
@MainActor
public protocol ExtensionContext: AnyObject, Sendable {
    /// The shared SwiftData store (models from every extension).
    var context: ModelContext { get }
    var extensions: [any DashExtension] { get }
    var permissions: any PermissionAsking { get }
    var dashii: any DashiiService { get }
    /// Report what happens; Dashii sees it before its next turn.
    var activity: ActivityLog { get }

    func isEnabled(_ item: any DashExtension) -> Bool
    /// Sends a prompt to the chat panel and shows it.
    func askDashii(_ prompt: String)
    /// Opens Settings/Extensions on an extension.
    func openManager(_ extensionID: String?)
    /// Adds a widget of `kind` to the dashboard.
    func addWidget(kind: String) throws
    /// The user's AI choices (model, effort, templates) for a widget or an extension's tasks.
    func aiSettings(_ scope: AIScope, tasks: [AITask]) -> AISettings
    /// Saves the user's choice for one task (nil resets it to the task's defaults), so an
    /// extension's own settings page can offer the model and effort pickers too.
    func setAIChoice(_ choice: AITaskChoice?, task: String, scope: AIScope)
    /// Writes a Markdown note into the user's notes vault (e.g. a meeting's notes) and returns
    /// its file. `folder` is a sub-folder of the vault, created if needed.
    func createNote(title: String, markdown: String, folder: String?) throws -> URL
    /// Runs an agent now ("<extension id>.<agent id>") and returns its report.
    func runAgent(_ id: String, reason: String) async throws -> AgentReport
    /// An agent's latest reports, newest first: what widgets show.
    func agentReports(_ id: String, limit: Int) -> [AgentReport]
    /// The mirror of online data that integrations sync and features read.
    var synced: any SyncedStore { get }
}

extension ExtensionContext {
    /// Default for hosts without a notes vault (test fakes).
    public func createNote(title: String, markdown: String, folder: String?) throws -> URL {
        throw ToolError("This host has no notes vault.")
    }

    /// Default for hosts without saved choices (test fakes): every task's defaults.
    public func aiSettings(_ scope: AIScope, tasks: [AITask]) -> AISettings { AISettings(tasks: tasks, scope: scope) }

    /// Default for hosts that don't run agents (test fakes).
    public func runAgent(_ id: String, reason: String) async throws -> AgentReport {
        throw ToolError("This host doesn't run agents.")
    }

    public func agentReports(_ id: String, limit: Int) -> [AgentReport] { [] }

    /// Default for hosts without a persisted mirror (test fakes): one in memory per process.
    public var synced: any SyncedStore { DefaultSynced.store }

    /// Default for hosts without saved choices (test fakes): ignored.
    public func setAIChoice(_ choice: AITaskChoice?, task: String, scope: AIScope) {}

    public func ext<T: DashExtension>(_ type: T.Type) -> T? {
        extensions.lazy.compactMap { $0 as? T }.first
    }

    public func integration(_ id: String) -> (any Integration)? {
        extensions.lazy.compactMap { $0 as? any Integration }.first { $0.id == id && $0.layer == .integration }
    }

    public func integration<T: Integration>(_ type: T.Type) -> T? {
        extensions.lazy.compactMap { $0 as? T }.first
    }

    /// Shorthand for `activity.emit` with this extension as the source.
    @discardableResult
    public func emit(_ kind: String, from item: any DashExtension, title: String, detail: String? = nil, link: String? = nil,
                     importance: ActivityEvent.Importance = .info) -> ActivityEvent {
        activity.emit(kind, source: item.id, title: title, detail: detail, link: link, importance: importance)
    }
}
