import DashKit
import Foundation
import Testing
@testable import Dash

@MainActor
@Suite("Synced mirror")
struct SyncedMirrorTests {
    @Test func replaceMirrorsTheServiceExactly() throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "sync-\(UUID())")!), extensions: [], inMemory: true)
        let store = host.synced
        func tag(_ name: String, _ sha: String) -> SyncedRecord {
            SyncedRecord(kind: "git.tag", scope: "github:acme/api", key: name, value: ["commit": .string(sha)], source: "github")
        }
        #expect(store.lastSynced(kind: "git.tag", scope: "github:acme/api") == nil)
        store.replace(kind: "git.tag", scope: "github:acme/api", with: [tag("v1", "a"), tag("v2", "b")])
        #expect(store.records(kind: "git.tag", scope: "github:acme/api").map(\.key) == ["v1", "v2"])
        #expect(store.lastSynced(kind: "git.tag", scope: "github:acme/api") != nil)
        // The service deleted v1 and moved v2: the mirror follows.
        store.replace(kind: "git.tag", scope: "github:acme/api", with: [tag("v2", "c"), tag("v3", "d")])
        #expect(store.records(kind: "git.tag", scope: "github:acme/api").map(\.key) == ["v2", "v3"])
        #expect(store.record(kind: "git.tag", scope: "github:acme/api", key: "v2")?.value["commit"] == "c")
        // Other scopes and kinds are untouched.
        store.upsert([SyncedRecord(kind: "git.range", scope: "github:acme/api", key: "a...b", value: [], source: "github")])
        store.replace(kind: "git.tag", scope: "github:acme/web", with: [])
        #expect(store.record(kind: "git.range", scope: "github:acme/api", key: "a...b") != nil)
        #expect(store.records(kind: "git.tag", scope: "github:acme/api").count == 2)
    }
}
