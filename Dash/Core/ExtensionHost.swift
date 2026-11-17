@_spi(DashHost) import DashKit
@_spi(DashHost) import DashKitUI
import Foundation
import Observation
import SwiftData

/// Owns the extensions, the shared SwiftData store and the Claude request defaults.
@MainActor
@Observable
final class ExtensionHost: ExtensionContext {
    let settings: AppSettings
    let permissionCenter = PermissionCenter()
    /// Claude's name and voice, and the mascot's settings.
    let persona = Persona()
    var permissions: any PermissionAsking { permissionCenter }
    /// Everything that happens on the dashboard; Claude reads it before each turn.
    let activity = ActivityLog()
    private(set) var extensions: [any DashExtension]
    /// `.dashplugin` bundles found at launch or installed since.
    var plugins: [PluginRecord] = []
    /// Problems with the installed extensions (a feature whose integration is missing).
    private(set) var extensionErrors: [String] = []
    /// Integrations and features the user turned off.
    private(set) var disabled: Set<String> = Set(DashDefaults.shared.stringArray(forKey: "dash.disabledExtensions") ?? [])
    /// What the main area shows: "page" (the selected page) or "notes".
    var mainView = "page"
    /// The page on screen.
    var selectedPageID: UUID? = UUID(uuidString: DashDefaults.shared.string(forKey: "dash.selectedPage") ?? "") {
        didSet { DashDefaults.shared.set(selectedPageID?.uuidString, forKey: "dash.selectedPage") }
    }
    /// The page's layout is unlocked (⌘E, or press and hold a widget's header): widgets wiggle and
    /// can be moved, resized, removed and added from the gallery.
    var layoutEditing = false
    /// The widget gallery sheet is open.
    var widgetGalleryVisible = false

    /// What the Home page proposes: plugins' own suggestions, then anything important from the
    /// last day's activity, then setup steps while little is configured. Dismissed ones are left out.
    var homeSuggestions: [Suggestion] {
        let home = ext(HomeExtension.self)
        var items: [Suggestion] = []
        for item in extensions where isEnabled(item) {
            items += item.suggestions.map { var suggestion = $0; suggestion.source = item.id; return suggestion }
        }
        let dayAgo = Date.now.addingTimeInterval(-86_400)
        for event in activity.events.reversed() where event.date > dayAgo && event.importance >= .notable {
            items.append(Suggestion(
                id: "event.\(event.id)", title: event.title, detail: event.detail,
                icon: event.importance == .critical ? "exclamationmark.triangle" : "bell",
                priority: event.importance == .critical ? .urgent : .normal,
                prompt: "Tell me what I should know about this, and what to do: \(event.title)\(event.detail.map { ". \($0)" } ?? "")",
                link: event.link.flatMap(URL.init(string:)), source: event.source))
            if items.count >= 12 { break }
        }
        if !extensions.contains(where: { $0.layer == .integration }) {
            items.append(Suggestion(id: "setup.plugins", title: "Install your first plugins",
                                    detail: "GitHub, Jira, Kubernetes… from the Marketplace.", icon: "bag", priority: .high, source: "marketplace"))
        }
        if home?.userName.isEmpty != false || home?.role.isEmpty != false {
            items.append(Suggestion(id: "setup.profile", title: "Tell \(persona.name) about you",
                                    detail: "Your name, role and focus make suggestions and the brief fit your work.",
                                    icon: "person.crop.circle", source: "home"))
        }
        if !settings.isClaudeConfigured {
            items.append(Suggestion(id: "setup.claude", title: "Set up Dashii", detail: "Install its engine (Claude Code) and log in with claude /login.",
                                    icon: "sparkles", priority: .urgent, source: "claude"))
        }
        let dismissed = home?.dismissed ?? []
        var seen = Set<String>()
        return items
            .filter { !dismissed.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.priority > $1.priority }
    }

    /// Opens the widget gallery, unlocking the layout so new widgets can be placed right away.
    func openWidgetGallery() {
        layoutEditing = true
        widgetGalleryVisible = true
    }
    /// The Settings tab on screen, and the extension to open in it (set by `openManager`).
    var settingsTab = "claude"
    /// Segments inside the Claude tab ("setup", "usage") and the Plugins tab
    /// ("integrations", "features", "installed").
    var claudeSection = "setup"
    /// Settings › Automation segment: "rules", "commands" or "hooks".
    var automationSection = "rules"
    var pluginsSection = "integrations"
    var managerSelection: String?
    /// Opens the Settings window (installed by the root view, which owns `openSettings`).
    @ObservationIgnored var openManagerWindow: (() -> Void)?
    /// Re-created when a hot-installed plugin brings new SwiftData models.
    private(set) var container: ModelContainer
    /// Tests: an in-memory store, no folder watching.
    @ObservationIgnored let inMemory: Bool
    @ObservationIgnored private(set) var dashboard: DashboardStore!
    @ObservationIgnored weak var chat: ChatSession?
    /// The mirror of online data integrations sync and features read.
    @ObservationIgnored private(set) lazy var syncedMirror = SyncedMirror(host: self)
    var synced: any SyncedStore { syncedMirror }
    /// Containers replaced when a hot-installed plugin grew the schema, kept so their models stay valid.
    @ObservationIgnored private var retiredContainers: [ModelContainer] = []

    var context: ModelContext { container.mainContext }
    /// Claude for features and plugins: Claude Code with the user's Claude login.
    var dashii: any DashiiService { ClaudeCodeService(settings: settings) }

    init(settings: AppSettings, extensions: [any DashExtension], inMemory: Bool = false) throws {
        self.settings = settings
        self.extensions = extensions
        self.inMemory = inMemory
        container = try Self.makeContainer(models: extensions.flatMap(\.models), inMemory: inMemory)
        if !inMemory { DatabaseVault.shared.attach(container) }
        dashboard = DashboardStore(host: self)
        permissionCenter.store = container.mainContext
        if !inMemory { ClaudeUsage.shared.host = self }
        AutomationStore.shared.host = self
    }

    /// The store with Dash's own models plus every extension's. Adding models to an existing
    /// store is a lightweight migration, so hot-installed plugins can grow the schema.
    static func makeContainer(models: [any PersistentModel.Type], inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([WidgetRecord.self, DashboardPage.self, SidebarSection.self, ClaudeCall.self,
                             AutomationRule.self, AutomationCommand.self, AutomationHook.self, HookRun.self, StoredSecret.self, ChatConversation.self, SyncedRecordModel.self, DashSkill.self, PermissionGrant.self] + models)
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: try storeURL())
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Ids of the extensions that ship inside Dash (not plugins).
    static let builtInIDs: Set<String> = ["basics", "home", "notes", "knowledge", "agents-studio", "marketplace", "git", "jj"]

    static func builtInExtensions() -> [any DashExtension] {
        // Everything else (integrations and features) is a plugin installed from the Marketplace;
        // features find integrations by id.
        [BasicsExtension(), HomeExtension(), NotesExtension(), KnowledgeExtension(), AgentsStudio(), MarketplaceFeature(),
         GitIntegration(), JujutsuIntegration()]
    }

    /// ~/Library/Application Support/Dash/Dash.store
    nonisolated static func storeURL() throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Dash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "Dash.store")
    }

    func start() {
        disableNewPlugins(extensions)
        // Who `me` is in widgets' DashQL queries.
        WidgetQuery.me = DashQL.me(host: self)
        Skills.seed(in: context)
        extensionErrors = dependencyErrors()
        for item in startOrder where isEnabled(item) {
            DashLog.info("Starting \(item.id) \(item.metadata.version)", category: "extensions")
            item.start(host: self)
        }
        for error in extensionErrors { DashLog.error(error, category: "extensions") }
        dashboard.seedIfEmpty()
        dashboard.seedHome()
    }

    private var startOrder: [any DashExtension] {
        extensions.filter { $0.layer == .integration } + extensions.filter { $0.layer == .feature }
    }

    // MARK: Layers

    var integrations: [any Integration] { extensions.compactMap { $0 as? any Integration }.filter { $0.layer == .integration } }


    /// Required ids that are missing, turned off, or (integrations) not connected. A feature may
    /// require another feature (Workspaces requires Agents): it must be installed and on.
    func unmetRequirements(of item: any DashExtension) -> [String] {
        item.requires.filter { id in
            if let integration = integration(id) { return !isEnabled(integration) || !integration.isConnected }
            if let feature = extensions.first(where: { $0.id == id }) { return !isEnabled(feature) }
            return true
        }
    }

    /// Features built on an integration (required or optional).
    func features(using integrationID: String) -> [any DashExtension] {
        extensions.filter { $0.requires.contains(integrationID) || $0.optional.contains(integrationID) }
    }

    /// The extension that contributes a widget kind.
    func owner(ofWidget kind: String) -> (any DashExtension)? {
        extensions.first { $0.widgets.contains { $0.kind == kind } }
    }

    private func dependencyErrors() -> [String] {
        extensions.flatMap { item in
            item.requires.filter { id in !extensions.contains { $0.id == id } }.map { "\(item.name) requires \"\($0)\", which is not installed." }
        }
    }

    /// Tools from enabled extensions whose integrations are all connected, minus the ones that
    /// write remotely or call a service: Claude reads Dash's database and asks for fetches.
    var availableTools: [DashiiTool] {
        extensions.filter { isEnabled($0) && unmetRequirements(of: $0).isEmpty }.flatMap(\.tools).filter(\.isForDashii)
    }

    /// Plugins arrive turned off: the user turns each one on (Settings › Plugins) before it runs,
    /// syncs or offers tools. The first time this runs, what's already installed is taken as known,
    /// so nothing the user uses gets switched off.
    func disableNewPlugins(_ items: [any DashExtension]) {
        let builtIn = Set(Self.builtInExtensions().map(\.id))
        let key = "dash.knownExtensions"
        guard var known = DashDefaults.shared.stringArray(forKey: key).map(Set.init) else {
            DashDefaults.shared.set(extensions.map(\.id).sorted(), forKey: key)
            return
        }
        let new = items.filter { !builtIn.contains($0.id) && !known.contains($0.id) }
        guard !new.isEmpty else { return }
        for item in new {
            disabled.insert(item.id)
            known.insert(item.id)
        }
        DashDefaults.shared.set(disabled.sorted(), forKey: "dash.disabledExtensions")
        DashDefaults.shared.set(known.sorted(), forKey: key)
        activity.emit("plugin.installed_off", source: "dashboard", title: "Installed \(new.map(\.name).joined(separator: ", ")), turned off",
                      detail: "Turn it on in Settings › Plugins when you want to use it.", importance: .notable)
    }

    func isEnabled(_ item: any DashExtension) -> Bool {
        !disabled.contains(item.id)
    }

    /// Turns an integration or feature on or off: its background work stops and its tools
    /// disappear. Features requiring a turned-off integration show "Connect…". Data and
    /// settings are kept.
    func setEnabled(_ item: any DashExtension, _ enabled: Bool) {
        guard enabled != isEnabled(item) else { return }
        if enabled {
            disabled.remove(item.id)
            item.start(host: self)
        } else {
            disabled.insert(item.id)
            item.stop()
        }
        DashDefaults.shared.set(disabled.sorted(), forKey: "dash.disabledExtensions")
        activity.emit(enabled ? "extension.enabled" : "extension.disabled", source: "dashboard",
                      title: "\(item.name) was turned \(enabled ? "on" : "off")", importance: .notable)
    }

    /// Opens Settings on the tab for `extensionID` (Integrations or Features) with it selected.
    func openManager(_ extensionID: String? = nil) {
        if extensionID == "marketplace" {
            settingsTab = "marketplace"
            managerSelection = nil
        } else if extensionID == "claude" {
            settingsTab = "claude"
            claudeSection = "setup"
            managerSelection = nil
        } else if let extensionID, let item = extensions.first(where: { $0.id == extensionID }) {
            settingsTab = "plugins"
            pluginsSection = item.layer == .integration ? "integrations" : "features"
            managerSelection = extensionID
        } else {
            settingsTab = "plugins"
            pluginsSection = "integrations"
        }
        openManagerWindow?()
    }

    /// Adds extensions without loading the Extensions folder (tests).
    func install(forTesting items: [any DashExtension]) {
        extensions += items
    }

    /// Adds extensions from a plugin loaded while Dash runs (hot install): grows the store's
    /// schema if the plugin brings models, then starts and prepares them.
    func addHotLoaded(_ items: [any DashExtension]) throws {
        guard !items.isEmpty else { return }
        let added = items.flatMap(\.models)
        let known = Set(extensions.flatMap(\.models).map { ObjectIdentifier($0) })
        if added.contains(where: { !known.contains(ObjectIdentifier($0)) }) {
            try? context.save()
            // The old container stays alive: models running extensions still hold (a sync waiting on
            // the network, an open sheet) stay usable instead of crashing as destroyed.
            retiredContainers.append(container)
            container = try Self.makeContainer(models: (extensions + items).flatMap(\.models), inMemory: inMemory)
            if !inMemory { DatabaseVault.shared.attach(container) }
            DashLog.info("Store schema grown for \(items.map(\.id).joined(separator: ", "))", category: "plugins")
        }
        extensions += items
        disableNewPlugins(items)
        extensionErrors = dependencyErrors()
        let ordered = items.filter { $0.layer == .integration } + items.filter { $0.layer == .feature }
        for item in ordered where isEnabled(item) {
            DashLog.info("Hot-starting \(item.id) \(item.metadata.version)", category: "plugins")
            item.start(host: self)
        }
        Task {
            for item in ordered where isEnabled(item) {
                do { try await item.prepare(host: self) } catch {
                    DashLog.error("\(item.name) couldn't prepare: \(error.localizedDescription)", category: "plugins")
                }
            }
        }
        activity.emit("plugin.loaded", source: "dashboard", title: "Loaded \(items.map(\.name).joined(separator: ", "))", importance: .notable)
    }

    func stop() {
        for item in extensions { item.stop() }
    }


    /// Widgets that can be placed: from installed, enabled extensions only.
    var widgetTypes: [WidgetType] { extensions.filter { isEnabled($0) }.flatMap(\.widgets) }

    /// Each placed widget's live link to Dashii (actions, UI state, attention).
    @ObservationIgnored private var liveWidgets: [UUID: WidgetLiveState] = [:]

    func live(_ widgetID: UUID) -> WidgetLiveState {
        if let live = liveWidgets[widgetID] { return live }
        let live = WidgetLiveState()
        liveWidgets[widgetID] = live
        return live
    }

    func widgetType(_ kind: String) -> WidgetType? {
        widgetTypes.first { $0.kind == kind }
    }

    /// A placed widget shows only while its extension is installed and enabled; otherwise it's
    /// hidden (its layout and settings are kept, and it returns when the extension does).
    func isWidgetAvailable(_ kind: String) -> Bool { widgetType(kind) != nil }

    func addWidget(kind: String) throws {
        _ = try dashboard.add(kind: kind)
    }

    func createNote(title: String, markdown: String, folder: String?) throws -> URL {
        guard let notes = ext(NotesExtension.self) else { throw ToolError("Notes isn't available.") }
        // A report generated again (same title, same folder) replaces its note instead of adding a copy.
        if let existing = notes.store.note(titled: title), existing.folder == (folder ?? "") {
            try notes.store.write(markdown, to: existing)
            return existing.url
        }
        let note = try notes.store.create(title: title, markdown: markdown, folder: folder)
        activity.emit("note.created", source: "notes", title: "Note “\(note.title)” created", importance: .info)
        return note.url
    }

    // MARK: AI choices

    /// Bumped on every change so views showing AI settings refresh.
    private(set) var aiRevision = 0

    private static func aiKey(_ scope: AIScope) -> String { "dash.ai.\(scope)" }

    /// Saved choices for a widget or an extension, by task id.
    func aiChoices(_ scope: AIScope) -> [String: AITaskChoice] {
        _ = aiRevision
        guard let data = DashDefaults.shared.data(forKey: Self.aiKey(scope)) else { return [:] }
        return (try? JSONDecoder().decode([String: AITaskChoice].self, from: data)) ?? [:]
    }

    func setAIChoice(_ choice: AITaskChoice?, task: String, scope: AIScope) {
        var choices = aiChoices(scope)
        choices[task] = choice
        DashDefaults.shared.set(choices.isEmpty ? nil : try? JSONEncoder().encode(choices), forKey: Self.aiKey(scope))
        aiRevision += 1
        activity.emit("ai.settings", source: "dashboard", title: "Changed AI settings for \(task)")
    }

    func clearAIChoices(_ scope: AIScope) {
        DashDefaults.shared.removeObject(forKey: Self.aiKey(scope))
        aiRevision += 1
    }

    func runAgent(_ id: String, reason: String) async throws -> AgentReport {
        try await AgentHub.shared.run(id, reason: reason)
    }

    func agentReports(_ id: String, limit: Int) -> [AgentReport] {
        AgentHub.shared.reports(id, limit: limit)
    }

    func aiSettings(_ scope: AIScope, tasks: [AITask]) -> AISettings {
        AISettings(tasks: tasks, choices: aiChoices(scope), scope: scope)
    }

    /// Sends a prompt to the chat panel and shows it.
    func askDashii(_ prompt: String) {
        chat?.isPanelVisible = true
        chat?.send(prompt)
    }

    /// Starts a request in the chat's composer for the user to finish and send.
    func draftForClaude(_ text: String) {
        chat?.isPanelVisible = true
        chat?.pendingDraft = text
    }
}
