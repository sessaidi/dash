import DashKit
import Foundation
import Testing
@testable import Dash

/// Preferences kept in the database instead of a plist.
@MainActor
struct DatabaseDefaultsTests {
    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dash-prefs-\(UUID().uuidString).store")
    }

    @Test func typedValuesSurviveReopening() throws {
        let url = storeURL()
        let defaults = try DatabaseDefaults(url: url)
        defaults.set("opus", forKey: "model")
        defaults.set(true, forKey: "flag")
        defaults.set(42, forKey: "count")
        defaults.set(1.5, forKey: "ratio")
        defaults.set(["a", "b"], forKey: "list")
        defaults.set(Data([1, 2]), forKey: "blob")
        defaults.set(["k": 1], forKey: "map")
        defaults.set("gone", forKey: "removed")
        defaults.removeObject(forKey: "removed")
        defaults.flush()

        let reopened = try DatabaseDefaults(url: url)
        #expect(reopened.string(forKey: "model") == "opus")
        #expect(reopened.bool(forKey: "flag") && reopened.object(forKey: "flag") as? Bool == true)
        #expect(reopened.integer(forKey: "count") == 42 && reopened.object(forKey: "count") as? Int == 42)
        #expect(reopened.double(forKey: "ratio") == 1.5)
        #expect(reopened.stringArray(forKey: "list") == ["a", "b"])
        #expect(reopened.data(forKey: "blob") == Data([1, 2]))
        #expect(reopened.dictionary(forKey: "map")?["k"] as? Int == 1)
        #expect(reopened.object(forKey: "removed") == nil)
        #expect(!reopened.bool(forKey: "missing") && reopened.integer(forKey: "missing") == 0)
    }

    @Test func registeredDefaultsAndImportOnce() throws {
        let defaults = try DatabaseDefaults(url: nil)
        defaults.register(defaults: ["fallback": "yes"])
        #expect(defaults.bool(forKey: "fallback"))
        defaults.importOnce(from: ["agents.codeRoot": "~/code", "NSWindow Frame Main": "0 0 10 10", "fallback": false])
        #expect(defaults.string(forKey: "agents.codeRoot") == "~/code")
        #expect(defaults.object(forKey: "NSWindow Frame Main") == nil)
        #expect(defaults.bool(forKey: "fallback") == false)
        // Only once: a key removed afterwards doesn't come back.
        defaults.removeObject(forKey: "agents.codeRoot")
        defaults.importOnce(from: ["agents.codeRoot": "~/code"])
        #expect(defaults.object(forKey: "agents.codeRoot") == nil)
    }

    @Test func observersSeeChanges() throws {
        final class Seen: @unchecked Sendable { var values: [String?] = [] }
        let defaults = try DatabaseDefaults(url: nil)
        let seen = Seen()
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { note in
            seen.values.append((note.object as? UserDefaults)?.string(forKey: "k"))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        defaults.set("v", forKey: "k")
        #expect(seen.values == ["v"])
    }

    @Test func dashUsesTheDatabaseForEveryone() {
        #expect(DashDefaults.shared is DatabaseDefaults)
        #expect(DashStorage.defaults === DashDefaults.shared)
        #expect(PreferenceStore.defaults === DashDefaults.shared)
    }
}
