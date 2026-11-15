import DashKit
import DashKitUI
import Foundation
import SwiftData
import Testing
@testable import Dash
import ClaudeCodeKit
import DashKitTesting

@MainActor
@Suite(.serialized)
struct FoundationTests {
    private func host() throws -> ExtensionHost {
        try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                          extensions: ExtensionHost.builtInExtensions(), inMemory: true)
    }

    @Test func disablingHidesToolsAndPausesDependentFeatures() throws {
        let host = try host()
        defer { UserDefaults.standard.removeObject(forKey: "dash.disabledExtensions") }
        let marketplace = try #require(host.ext(MarketplaceFeature.self))
        #expect(host.availableTools.contains { $0.name == "marketplace_list" })
        host.setEnabled(marketplace, false)
        #expect(!host.isEnabled(marketplace))
        #expect(!host.availableTools.contains { $0.name == "marketplace_list" })
        host.setEnabled(marketplace, true)
        #expect(host.availableTools.contains { $0.name == "marketplace_list" })

        let github = FakeIntegration(id: "github", connected: true)
        let pulls = FakeFeature(id: "pull-requests", requires: ["github"])
        host.install(forTesting: [github, pulls])
        host.setEnabled(github, false)
        #expect(!host.isEnabled(github))
        #expect(host.unmetRequirements(of: pulls) == ["github"])
        #expect(!host.availableTools.contains { $0.name == "github_api_get" })
        host.setEnabled(github, true)
    }

    @Test func secretsAreScopedPerExtensionWithLegacyFallback() {
        let legacyAccount = "test-legacy-\(UUID().uuidString)"
        let store = SecretStore(extensionID: "test-ext-\(UUID().uuidString)", legacy: ["token": legacyAccount])
        defer { store.write("token", nil); Keychain.write(nil, for: legacyAccount) }
        Keychain.write("old", for: legacyAccount)
        #expect(store.read("token") == "old")
        store.write("token", "new")
        #expect(store.read("token") == "new" && Keychain.read(store.account("token")) == "new")
        store.write("token", nil)
        #expect(store.read("token") == nil && Keychain.read(legacyAccount) == nil)
    }

    @Test func preferencesListAndResetByPrefix() {
        let store = PreferenceStore(prefix: "test-prefs-\(UUID().uuidString)")
        store.set("a", "one")
        store.set(true, "two")
        #expect(store.storedKeys.count == 2 && store.string("one") == "a" && store.bool("two") == true)
        store.removeAll()
        #expect(store.storedKeys.isEmpty)
    }

    @Test func dataSummaryCountsAndDeletesAnExtensionsModels() throws {
        // The feature's model has to be in the store's schema, so it's passed at creation.
        let notes = FakeFeature(id: "notes")
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions() + [notes], inMemory: true)
        host.context.insert(FakeNote(text: "hello"))
        try host.context.save()
        #expect(host.dataSummary(for: notes).first { $0.model == "FakeNote" }?.count == 1)
        host.deleteData(for: notes)
        #expect(host.dataSummary(for: notes).allSatisfy { $0.count == 0 })
    }

    @Test func widgetsFromOlderStoresGetPlacedOnTheGrid() throws {
        let host = try host()
        for index in 0..<3 {
            host.context.insert(WidgetRecord(kind: "note", title: "N\(index)", size: .small, config: ["text": ""], order: index))
        }
        try host.context.save()
        host.dashboard.migrate()
        let frames = host.dashboard.widgets().map(\.frame)
        #expect(host.dashboard.pages().map(\.name) == ["Home"])
        #expect(host.dashboard.widgets().allSatisfy { $0.pageID == host.dashboard.pages().first?.id })
        #expect(frames == [GridFrame(x: 0, y: 0, w: 3, h: 4), GridFrame(x: 3, y: 0, w: 3, h: 4), GridFrame(x: 6, y: 0, w: 3, h: 4)])
    }

    @Test func widgetsRiseToFillGapsAfterMovesAndRemovals() throws {
        let host = try host()
        let top = try host.dashboard.add(kind: "note", size: .wide)
        let below = try host.dashboard.add(kind: "note", size: .wide)
        #expect(below.frame.y == 9)
        // Removing a widget lets the one below rise into its space, same size.
        try host.dashboard.remove(top.id)
        #expect(try host.dashboard.widget(below.id).frame == GridFrame(x: 0, y: 0, w: 8, h: 9))
        // Dropped lower down with nothing above, it floats back to the top.
        try host.dashboard.place(below.id, x: 4, y: 20)
        #expect(try host.dashboard.widget(below.id).frame == GridFrame(x: 4, y: 0, w: 8, h: 9))
    }

    @Test func resizesRespectTheWidgetsLimits() throws {
        let host = try host()
        // Claude Usage: 3x4 up to 8x10.
        let usage = try host.dashboard.add(kind: "claude.usage")
        try host.dashboard.place(usage.id, w: 12, h: 30)
        #expect(try host.dashboard.widget(usage.id).frame.w == 8)
        #expect(try host.dashboard.widget(usage.id).frame.h == 10)
        try host.dashboard.place(usage.id, w: 1, h: 1)
        #expect(try host.dashboard.widget(usage.id).frame.w == 3)
        #expect(try host.dashboard.widget(usage.id).frame.h == 4)
    }
}

@MainActor
struct PageTests {
    private func host() throws -> ExtensionHost {
        try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                          extensions: ExtensionHost.builtInExtensions(), inMemory: true)
    }

    @Test func pagesHaveIndependentGrids() throws {
        let host = try host()
        host.dashboard.migrate()
        let home = try #require(host.dashboard.pages().first)
        let oncall = host.dashboard.createPage(name: "On-call", systemImage: "bell")
        let a = try host.dashboard.add(kind: "note", page: home.id)
        let b = try host.dashboard.add(kind: "note", page: oncall.id)
        // Each page starts at the top-left.
        #expect(a.frame.x == 0 && a.frame.y == 0 && b.frame.x == 0 && b.frame.y == 0)
        #expect(host.dashboard.widgets(on: oncall.id).map(\.id) == [b.id])

        try host.dashboard.place(a.id, page: oncall.id)
        #expect(host.dashboard.widgets(on: home.id).isEmpty)
        let onCall = host.dashboard.widgets(on: oncall.id)
        #expect(onCall.count == 2 && onCall[0].frame != onCall[1].frame)
    }

    @Test func deletingAPageDeletesItsWidgetsButKeepsOne() throws {
        let host = try host()
        host.dashboard.migrate()
        let home = try #require(host.dashboard.pages().first)
        #expect(throws: ToolError.self) { try host.dashboard.deletePage(home.id) }
        let extra = host.dashboard.createPage(name: "Extra")
        _ = try host.dashboard.add(kind: "note", page: extra.id)
        try host.dashboard.deletePage(extra.id)
        #expect(host.dashboard.pages().count == 1 && host.dashboard.widgets().isEmpty)
        #expect(host.activity.events.contains { $0.kind == "page.deleted" })
    }

    @Test func pageToolsAndActivityReachClaude() async throws {
        let host = try host()
        host.dashboard.migrate()
        let tools = CoreTools.tools(host: host)
        let create = try #require(tools.first { $0.name == "create_page" })
        let page = try await create.run(["name": "Deploys", "icon": "server.rack"])
        let pageID = try #require(page["id"]?.string)
        let add = try #require(tools.first { $0.name == "add_widget" })
        _ = try await add.run(["kind": "note", "page_id": .string(pageID)])
        let activity = try #require(tools.first { $0.name == "dashboard_activity" })
        let events = try await activity.run(["minutes": 5])
        #expect(events.array?.compactMap { $0["kind"]?.string }.contains("page.created") == true)
        #expect(events.array?.compactMap { $0["kind"]?.string }.contains("widget.added") == true)
    }
}

@MainActor
struct HotInstallTests {
    @Test func hotLoadedFeatureGrowsTheStoreAndStarts() throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        let kept = try host.dashboard.add(kind: "note", title: "Kept")
        let before = ObjectIdentifier(host.container)
        // FakeNote isn't in the launch schema; adding the feature has to grow it.
        let notes = FakeFeature(id: "hot-notes")
        try host.addHotLoaded([notes])
        #expect(ObjectIdentifier(host.container) != before)
        // A model fetched before the schema grew (a sync holding it across an await) stays usable.
        kept.title = "Still usable"
        #expect(kept.title == "Still usable")
        #expect(host.extensions.contains { $0.id == "hot-notes" })
        #expect(host.availableTools.contains { $0.name == "hot-notes_run" })
        host.context.insert(FakeNote(text: "hello"))
        try host.context.save()
        #expect(host.dataSummary(for: notes).first { $0.model == "FakeNote" }?.count == 1)
        #expect(host.activity.events.contains { $0.kind == "plugin.loaded" })
    }

    @Test func hotLoadingWithoutNewModelsKeepsTheStore() throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        let before = ObjectIdentifier(host.container)
        try host.addHotLoaded([FakeIntegration(id: "github", connected: true)])
        #expect(ObjectIdentifier(host.container) == before)
        #expect(host.integration("github") != nil)
    }
}

@MainActor
struct WidgetAvailabilityTests {
    @Test func widgetsOfMissingOrDisabledExtensionsCantBeAddedAndAreHidden() throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        // Nothing provides this kind: refused.
        #expect(throws: ToolError.self) { try host.dashboard.add(kind: "jira.board") }
        let clock = try host.dashboard.add(kind: "claude.usage")
        #expect(host.isWidgetAvailable("claude.usage"))
        // Turning Basics off hides its widgets and stops new ones; they come back when it's on.
        let basics = try #require(host.extensions.first { $0.id == "basics" })
        host.setEnabled(basics, false)
        #expect(!host.isWidgetAvailable("claude.usage"))
        #expect(throws: ToolError.self) { try host.dashboard.add(kind: "note") }
        #expect(host.dashboard.frames(on: clock.pageID)[clock.id] == nil)
        #expect((try? host.dashboard.widget(clock.id)) != nil)          // kept, not deleted
        host.setEnabled(basics, true)
        #expect(host.dashboard.frames(on: clock.pageID)[clock.id] != nil)
    }
}

@MainActor
struct ClaudeUsageTests {
    private func result(cost: Double, input: Int, output: Int, error: Bool = false) throws -> ResultMessage {
        let json = try JSON.parse("""
        {"type": "result", "subtype": "\(error ? "error_during_execution" : "success")", "is_error": \(error), "total_cost_usd": \(cost),
         "duration_ms": 1200, "num_turns": 2, "result": "ok",
         "usage": {"input_tokens": \(input), "output_tokens": \(output), "cache_read_input_tokens": 100, "cache_creation_input_tokens": 0}}
        """)
        guard case .result(let message) = Message(json) else { throw ToolError("not a result") }
        return message
    }

    @Test func callsAreStoredAndTotalled() throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        let usage = ClaudeUsage()
        usage.host = host
        usage.record(source: "chat", model: "claude-opus-5-5", effort: "high", result: try result(cost: 0.05, input: 1000, output: 200))
        usage.record(source: "extension.pull-requests/review", model: "claude-sonnet-5-5", effort: nil,
                     result: try result(cost: 0.01, input: 500, output: 50, error: true))
        // Yesterday's call isn't in today's totals.
        usage.record(source: "chat", model: "claude-opus-5-5", effort: nil, result: try result(cost: 1, input: 1, output: 1),
                     now: .now.addingTimeInterval(-2 * 86_400))
        let today = usage.totals(days: 1)
        #expect(today.calls == 2 && today.errors == 1 && today.turns == 4)
        #expect(abs(today.costUSD - 0.06) < 1e-9)
        #expect(today.inputTokens == 1700 && today.outputTokens == 250)
        #expect(usage.totals(days: 7).calls == 3)
    }

    @Test func sourcesReadAsLabels() {
        #expect(ClaudeCall.label("chat") == "Chat")
        #expect(ClaudeCall.label("extension.pull-requests/review") == "Pull Requests › review")
        #expect(ClaudeCall.label("widget.0000/summarize") == "Widget › summarize")
        #expect(ClaudeCall.label("plugin") == "Plugin")
    }
}

@MainActor
struct HomeTests {
    @Test func suggestionsMixSetupStepsActivityAndDismissals() throws {
        let defaults = UserDefaults(suiteName: "dash-tests-\(UUID())")!
        let home = HomeExtension(defaults: defaults)
        home.userName = ""
        let host = try ExtensionHost(settings: AppSettings(defaults: defaults), extensions: [BasicsExtension(), home, MarketplaceFeature()], inMemory: true)
        host.activity.emit("deploy.failed", source: "kubernetes", title: "api crash-looping", importance: .critical)
        let ids = host.homeSuggestions.map(\.id)
        #expect(ids.contains("setup.plugins") && ids.contains("setup.profile"))
        let urgent = try #require(host.homeSuggestions.first)
        #expect(urgent.priority == .urgent)
        home.dismiss(urgent)
        #expect(!host.homeSuggestions.contains { $0.id == urgent.id })
    }

    @Test func greetsByGivenName() {
        #expect(HomeExtension.givenName("ESSAÏDI Sadik") == "Sadik")
        #expect(HomeExtension.givenName("Ada Lovelace") == "Ada")
        #expect(HomeExtension.givenName("ADA") == "Ada")
        #expect(HomeExtension.givenName("") == "")
    }

    @Test func briefUsesTheProfileAndTheAITabModel() async throws {
        let home = HomeExtension(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!)
        home.userName = "Ada"
        home.role = "backend engineer"
        let host = try TestHost([home])
        host.start([home])
        host.testClaude.reply = #"{"items": [{"title": "Review PR #12", "detail": "Waiting since yesterday", "prompt": "Summarize PR #12"}]}"#
        await home.writeBrief(context: "- PR #12 waits for you")
        #expect(home.brief?.items.map(\.title) == ["Review PR #12"])
        let call = try #require(host.testClaude.calls.last)
        #expect(call.prompt.contains("Ada, backend engineer") && call.prompt.contains("PR #12 waits"))
        #expect(call.model == ClaudeModel.sonnet.rawValue && call.source == "extension.home/brief")
        #expect(home.profilePrompt == "The user's name is Ada. They are backend engineer.")
    }
}

@Suite(.serialized)
@MainActor
struct SecretFileTests {
    @Test func fileStoreIsOwnerOnlyAndRoundTrips() throws {
        let saved = (Keychain.backend, Keychain.fileURL)
        defer { (Keychain.backend, Keychain.fileURL) = saved }
        let folder = FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        Keychain.fileURL = folder.appending(path: "secrets.json")
        Keychain.backend = .file
        let store = SecretStore(extensionID: "atlassian")
        store.write("token", "s3cr3t")
        #expect(store.read("token") == "s3cr3t")
        let attributes = try FileManager.default.attributesOfItem(atPath: Keychain.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        store.write("token", nil)
        #expect(store.read("token") == nil)
    }
}

@MainActor
struct VaultTests {
    @Test func encryptsSecretsInTheDatabase() throws {
        let container = try ModelContainer(for: StoredSecret.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let vault = DatabaseVault()
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        vault.keyURL = folder.appending(path: "vault.key")
        vault.attach(container)
        #expect(vault.write("s3cr3t-token", for: "atlassian.token"))
        #expect(vault.read("atlassian.token") == "s3cr3t-token")
        #expect(vault.accounts() == ["atlassian.token"])
        // What's stored isn't the token.
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<StoredSecret>()).first)
        #expect(!String(decoding: row.sealed, as: UTF8.self).contains("s3cr3t"))
        print("VAULT protection: \(vault.protection), sealed \(row.sealed.count) bytes")
        // Overwrite and delete.
        #expect(vault.write("new", for: "atlassian.token") && vault.read("atlassian.token") == "new")
        #expect(vault.write(nil, for: "atlassian.token") && vault.read("atlassian.token") == nil)
        // The key file holds only the Secure Enclave handle or the fallback key, owner-only.
        let attributes = try FileManager.default.attributesOfItem(atPath: vault.keyURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}
