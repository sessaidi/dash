import DashKit
import Foundation
import Testing
@testable import Dash

/// Watchers: hooks that run a DashQL query themselves and fire on new rows, no Claude.
@MainActor
struct WatcherTests {
    @Test func firesOnlyOnRowsNotSeenBefore() {
        let defaults = UserDefaults(suiteName: "watchers-\(UUID())")!
        let hook = UUID()
        let first: [JSONValue] = [["name": "api-1", "restarts": 3], ["name": "api-2", "restarts": 7]]
        #expect(HookEngine.newRows(first, key: "name", hookID: hook, defaults: defaults).isEmpty)  // baseline
        #expect(HookEngine.newRows(first, key: "name", hookID: hook, defaults: defaults).isEmpty)  // nothing new
        let later: [JSONValue] = [["name": "api-2", "restarts": 9], ["name": "worker-1", "restarts": 6]]
        #expect(HookEngine.newRows(later, key: "name", hookID: hook, defaults: defaults) == [["name": "worker-1", "restarts": 6]])
        // Without a key, a changed row counts as new.
        let other = UUID()
        _ = HookEngine.newRows(first, key: nil, hookID: other, defaults: defaults)
        #expect(HookEngine.newRows([["name": "api-1", "restarts": 4]], key: nil, hookID: other, defaults: defaults).count == 1)
    }

    @Test func valuesForTheAction() {
        let values = HookEngine.watcherValues([["name": "worker-1", "namespace": "bill-eu", "restarts": 6], ["name": "x"]])
        #expect(values["count"] == "2" && values["first.name"] == "worker-1" && values["first.restarts"] == "6")
        #expect(values["rows"]?.contains("namespace: \"bill-eu\"") == true)
    }

    @Test func dashiiCanCreateAWatcher() throws {
        let trigger = try JSONDecoder().decode(HookTrigger.self, from: Data(#"{"query":{"query":"from pods where restarts > 5","everyMinutes":5,"key":"name"}}"#.utf8))
        #expect(trigger == .query(query: "from pods where restarts > 5", everyMinutes: 5, key: "name"))
        #expect(trigger.summary.contains("finds something new"))
    }

    @Test func presetsComeFromDashAndEnabledPlugins() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "presets-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions() + [PresetPlugin()], inMemory: true)
        let plugin = try #require(host.extensions.first { $0.id == "presetplugin" })
        host.setEnabled(plugin, true)
        let all = HookPreset.all(host: host)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.contains { $0.id == "dash.notify-critical" })
        let watch = try #require(all.first { $0.id == "presetplugin.crash" })
        #expect(watch.category == "Cluster" && watch.trigger == .query(query: "from pods where restarts > 5", everyMinutes: 5, key: "name"))
        #expect(all.first { $0.id == "presetplugin.wake" }?.category == "Preset Plugin")
        for preset in all { if case .query(let query, _, _) = preset.trigger { #expect((try? DashQuery.parse(query)) != nil, "\(preset.id)") } }

        let script = DashScript(host: host, tools: AppTools.tools(host: host)) { _, _ in nil }
        #expect(await script.run("hook preset presetplugin.crash")["error"] == nil)
        #expect((await script.run("hook preset presetplugin.wake"))["error"]?.string?.contains("agent=") == true)

        host.setEnabled(plugin, false)
        #expect(!HookPreset.all(host: host).contains { $0.id == "presetplugin.crash" })
    }
}

/// A plugin offering its own presets.
@MainActor
private final class PresetPlugin: DashExtension {
    let id = "presetplugin"
    let name = "Preset Plugin"
    let systemImage = "bolt"
    var hookPresets: [HookPresetSpec] {
        [.watch("presetplugin.crash", category: "Cluster", "Pods restarting", query: "from pods where restarts > 5", every: 5, key: "name",
                title: "{{first.name}}", body: "{{first.restarts}} restarts"),
         .wake("presetplugin.wake", "Investigate", query: "from pods where restarts > 5", every: 5, key: "name", context: "{{rows}}")]
    }
}

/// The SDK's preset library: every query parses, ids are prefixed and unique.
struct HookPresetLibraryTests {
    @Test func libraryPresetsAreWellFormed() throws {
        var ids: Set<String> = []
        for dataset in HookPresetLibrary.datasets {
            let presets = HookPresetLibrary.presets(for: dataset, extension: "plugin")
            #expect(!presets.isEmpty, "\(dataset)")
            for preset in presets {
                #expect(preset.id.hasPrefix("plugin.") && ids.insert(preset.id).inserted, "\(preset.id)")
                if case .watch(let query, _, _) = preset.trigger {
                    #expect((try? DashQuery.parse(query)) != nil, "\(preset.id): \(query)")
                    #expect(query.hasPrefix("from \(dataset) "), "\(preset.id)")
                }
            }
        }
        #expect(HookPresetLibrary.presets(for: "unknown", extension: "x").isEmpty)
        let stale = HookPresetSpec.stale("x.s", "Stale", dataset: "prs", where: "a = 1 or b = 2", dateField: "updated", olderThan: "-24h", key: "url", title: "t", body: "b")
        #expect(stale.trigger == .watch(query: "from prs where (a = 1 or b = 2) and updated < -24h", everyMinutes: 60, key: "url"))
    }
}
