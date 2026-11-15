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
        let values = HookEngine.watcherValues([["name": "worker-1", "namespace": "papi-eu", "restarts": 6], ["name": "x"]])
        #expect(values["count"] == "2" && values["first.name"] == "worker-1" && values["first.restarts"] == "6")
        #expect(values["rows"]?.contains("namespace: \"papi-eu\"") == true)
    }

    @Test func dashiiCanCreateAWatcher() throws {
        let trigger = try JSONDecoder().decode(HookTrigger.self, from: Data(#"{"query":{"query":"from pods where restarts > 5","everyMinutes":5,"key":"name"}}"#.utf8))
        #expect(trigger == .query(query: "from pods where restarts > 5", everyMinutes: 5, key: "name"))
        #expect(trigger.summary.contains("finds something new"))
    }
}
