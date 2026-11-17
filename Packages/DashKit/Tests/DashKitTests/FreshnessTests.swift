import Foundation
import Testing
@testable import DashKit

/// Readers return stored rows with their freshness, or a hint to fetch first.
@MainActor
struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func staleAfterTheWindowOrWhenNeverFetched() {
        let refresh: JSONValue = ["fetcher": "github.pull", "input": ["repo": "acme/billing-api", "number": 7]]
        let fresh = Freshness(syncedAt: now.addingTimeInterval(-60), maxAge: .seconds(900), refresh: refresh, now: now)
        #expect(!fresh.stale)
        #expect(fresh.json["synced_at"] == .string(now.addingTimeInterval(-60).formatted(.iso8601)))
        #expect(fresh.json["refresh"] == refresh)
        #expect(Freshness(syncedAt: now.addingTimeInterval(-901), maxAge: .seconds(900), refresh: nil, now: now).stale)
        let never = Freshness(syncedAt: nil, maxAge: .seconds(900), refresh: nil, now: now)
        #expect(never.stale)
        #expect(never.json == ["synced_at": nil, "stale": true, "refresh": nil])
    }

    @Test func rowsCarryTheirFreshness() {
        let store = MemorySyncedStore()
        store.upsert([
            SyncedRecord(kind: "acme.item", scope: "acme", key: "a", value: ["n": 1], source: "acme", updatedAt: .now.addingTimeInterval(-30)),
            SyncedRecord(kind: "acme.item", scope: "acme", key: "b", value: ["n": 2], source: "acme", updatedAt: .now.addingTimeInterval(-7200)),
        ])
        let rows = store.rows(kind: "acme.item", scope: "acme", maxAge: .seconds(3600)) { ["fetcher": "acme.items", "input": ["key": .string($0.key)]] }
        #expect(rows.map(\.value) == [["n": 1], ["n": 2]])
        #expect(rows.map(\.freshness.stale) == [false, true])
        #expect(rows[1].freshness.refresh == ["fetcher": "acme.items", "input": ["key": "b"]])
        #expect(store.rows(kind: "acme.other", scope: "acme", maxAge: .seconds(1)) { _ in nil }.isEmpty)
    }

    @Test func notFetchedSaysWhichFetcherToCall() {
        #expect(notFetched("github.checks", input: ["repo": "acme/billing-api", "ref": "main"]) == [
            "rows": [], "fetched": false, "hint": "Call data_fetch with fetcher github.checks",
            "refresh": ["fetcher": "github.checks", "input": ["repo": "acme/billing-api", "ref": "main"]],
        ])
    }

    @Test func queryKeyIgnoresKeyOrder() {
        let a: JSONValue = ["query": "is:pr", "kind": "issues"]
        let b = JSONValue.object(["kind": "issues", "query": "is:pr"])
        #expect(a.queryKey == b.queryKey)
        #expect(a.queryKey.count == 16 && a.queryKey.allSatisfy(\.isHexDigit))
        #expect(a.queryKey != (["query": "is:issue", "kind": "issues"] as JSONValue).queryKey)
    }

    @Test func cappedKeepsSmallValuesAndCutsBigOnes() {
        let small: JSONValue = ["a": [1, 2, 3]]
        #expect(small.capped(toBytes: 1000) == small)

        let items = JSONValue.array((0..<100).map { ["n": .number(Double($0)), "pad": .string(String(repeating: "x", count: 50))] })
        let list = items.capped(toBytes: 1000)
        #expect(list["truncated"] == true && list["total"] == 100)
        let kept = list["items"]?.array ?? []
        #expect(!kept.isEmpty && kept.count < 100 && kept.first == items[0])
        #expect(list.jsonString().utf8.count <= 1000)

        let text = JSONValue.string(String(repeating: "é", count: 5000)).capped(toBytes: 1000)
        #expect(text.string?.hasSuffix("…[truncated]") == true)
        #expect(text.jsonString().utf8.count <= 1000)

        let object = JSONValue.object(["blob": .string(String(repeating: "a", count: 5000))]).capped(toBytes: 1000)
        #expect(object["truncated"] == true && object["json"]?.string?.hasPrefix("{\"blob\":\"aaa") == true)
        #expect(object.jsonString().utf8.count <= 1000)
    }

    @Test func versionIs24() {
        #expect(DashKitInfo.version == "2.4.0")
    }
}
