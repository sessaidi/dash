import DashKit
import DashKitTesting
import Foundation
import Ingestor
import Testing

/// A clock tests move by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
func makeIngestor(_ store: any SyncedStore, clock: TestClock) -> Ingestor {
    var ingestor = Ingestor(source: "acme", scope: "acme:api.acme.test", store: store, maxAge: .seconds(600))
    ingestor.clock = { clock.now }
    return ingestor
}

@MainActor
struct IngestorTests {
    let repo = JSONSchema.string("owner/name")

    @Test func fetchStoresACleanAnswerAndReadsItBackWithItsFreshness() async throws {
        let store = MemorySyncedStore(), clock = TestClock()
        let ingestor = makeIngestor(store, clock: clock)
        let token = "ghp_" + String(repeating: "a", count: 36)
        let resource = IngestResource(kind: "acme.pull", reader: "acme_pull", summary: "A pull request.",
                                      properties: ["repo": repo], required: ["repo"]) { input in
            ["title": "Fix the invoice total", "repo": input["repo"] ?? .null, "note": .string("deploy with \(token)")]
        }

        let receipt = try await ingestor.fetch(resource, ["repo": "  acme/billing-api ", "ignored": "x"])
        #expect(receipt.stored == 1 && receipt.unchanged == 0)
        #expect(receipt.readWith == #"acme_pull {"repo":"acme/billing-api"}"#)
        #expect(receipt.keys.count == 1 && receipt.keys[0].hasPrefix("acme.pull/"))
        #expect(receipt.json["synced_at"]?.string == clock.now.formatted(.iso8601))

        let answer = try ingestor.read(resource, ["repo": "acme/billing-api"])
        #expect(answer["title"]?.string == "Fix the invoice total")
        #expect(answer["note"]?.string?.contains(token) == false)
        #expect(answer["stale"]?.bool == false)
        #expect(answer["refresh"] == ["fetcher": "acme.pull", "input": ["repo": "acme/billing-api"]])

        #expect(try await ingestor.fetch(resource, ["repo": "acme/billing-api"]).unchanged == 1)
        clock.advance(601)
        #expect(try ingestor.read(resource, ["repo": "acme/billing-api"])["stale"]?.bool == true)
        #expect(try ingestor.stored(resource, ["repo": "acme/billing-api"])?.freshness.stale == true)
    }

    @Test func readersSayWhatToFetchAndInputsAreChecked() async throws {
        let store = MemorySyncedStore(), clock = TestClock()
        var ingestor = makeIngestor(store, clock: clock)
        ingestor.transform = { field, value in field == "repo" ? value.lowercased() : value }
        ingestor.validate = { input in
            if let repo = input["repo"]?.string, !repo.contains("/") { throw ToolError("repo is owner/name.") }
        }
        let resource = IngestResource(kind: "acme.repo", reader: "acme_repo", summary: "A repository.", properties: ["repo": repo], required: ["repo"]) { $0 }

        let missing = try ingestor.read(resource, ["repo": "Acme/Billing-API"])
        #expect(missing["fetched"]?.bool == false)
        #expect(missing["refresh"] == ["fetcher": "acme.repo", "input": ["repo": "acme/billing-api"]])
        #expect(throws: ToolError("Give repo.")) { try ingestor.read(resource, [:]) }
        #expect(throws: ToolError("repo is owner/name.")) { try ingestor.read(resource, ["repo": "billing-api"]) }

        try await ingestor.fetch(resource, ["repo": "ACME/billing-api"])
        #expect(try ingestor.read(resource, ["repo": "acme/BILLING-api"])["repo"]?.string == "acme/billing-api")

        let unstarted = Ingestor(source: "acme", scope: "acme", store: nil, maxAge: .seconds(60), notStarted: "Acme isn't started.")
        #expect(throws: ToolError("Acme isn't started.")) { try unstarted.read(resource, ["repo": "acme/billing-api"]) }
    }

    @Test func queryShapedAnswersExpireAndBigOnesAreCapped() async throws {
        let store = MemorySyncedStore(), clock = TestClock()
        var ingestor = makeIngestor(store, clock: clock)
        ingestor.cap = 2_000
        let search = IngestResource(kind: "acme.search", reader: "acme_search", summary: "Search.",
                                    properties: ["q": JSONSchema.string("Query.")], required: ["q"], queryShaped: true) { input in
            .array((0..<500).map { .string("\(input["q"]?.string ?? "") result \($0)") })
        }
        try await ingestor.fetch(search, ["q": "invoice"])
        clock.advance(2 * 86_400)
        try await ingestor.fetch(search, ["q": "refund"])
        #expect(store.records(kind: "acme.search", scope: ingestor.scope).count == 1)
        #expect(try ingestor.read(search, ["q": "invoice"])["fetched"]?.bool == false)

        let refund = try ingestor.read(search, ["q": "refund"])
        #expect(refund["truncated"]?.bool == true && refund["total"]?.int == 500)
        #expect((refund["items"]?.array?.count ?? 0) < 500)
    }

    @Test func fetchersAndReadersComeFromTheResources() async throws {
        let store = MemorySyncedStore(), clock = TestClock()
        var current: Ingestor? = makeIngestor(store, clock: clock)
        let resources = [IngestResource(kind: "acme.issue", reader: "acme_issue", summary: "An issue.",
                                        properties: ["key": JSONSchema.string("KAN-123")], required: ["key"]) { ["key": $0["key"] ?? .null] }]
        let fetchers = Ingestor.fetchers(resources) { current }
        let readers = Ingestor.readers(resources) { current }
        #expect(fetchers.map(\.name) == ["acme.issue"] && readers.map(\.name) == ["acme_issue"])
        #expect(fetchers[0].summary == "An issue. Read it with acme_issue.")
        #expect(readers[0].description == "An issue. Reads what Dash fetched (data_fetch acme.issue), with synced_at and stale.")
        #expect(readers[0].isForDashii)

        let receipt = try await fetchers[0].fetch(["key": "KAN-123"])
        #expect(receipt["stored"]?.int == 1)
        #expect(try await readers[0].run(["key": "KAN-123"])["key"]?.string == "KAN-123")

        current = nil
        await #expect(throws: ToolError("acme.issue: the integration isn't started.")) { try await fetchers[0].fetch(["key": "KAN-123"]) }
    }

    @Test func rowsKeepTheNewestCopyOfEachItem() async throws {
        let store = MemorySyncedStore(), clock = TestClock()
        let ingestor = makeIngestor(store, clock: clock)
        var title = "old"
        let pulls = IngestResource(kind: "acme.pulls", reader: "acme_pulls", summary: "Pulls.", properties: ["repo": repo, "state": JSONSchema.string("")]) { _ in
            [["number": 1, "title": .string(title)], ["number": 2, "title": "other"]]
        }
        let pull = IngestResource(kind: "acme.pull", reader: "acme_pull", summary: "Pull.", properties: ["repo": repo]) { _ in ["number": 1, "title": "newest"] }
        try await ingestor.fetch(pulls, ["repo": "acme/billing-api", "state": "open"])
        clock.advance(60)
        try await ingestor.fetch(pull, ["repo": "acme/billing-api"])
        title = "elsewhere"
        try await ingestor.fetch(pulls, ["repo": "acme/web"])

        let rows = ingestor.rows([pulls, pull], stamp: ["repo"]) { $0["number"]?.int.map(String.init) ?? "" }
        #expect(rows.map { "\($0["repo"]?.string ?? "")#\($0["title"]?.string ?? "")" } == ["acme/billing-api#newest", "acme/billing-api#other", "acme/web#elsewhere", "acme/web#other"])
        #expect(rows.allSatisfy { $0["synced_at"]?.string != nil && $0["stale"]?.bool == false })
    }

    @Test func answersAndTheirDataAreInverses() {
        let freshness = Freshness(syncedAt: .now, maxAge: .seconds(60), refresh: nil)
        for data: JSONValue in [["title": "Fix"], [1, 2], "a log line", ["items": [1], "total": 1]] {
            #expect(Ingestor.data(of: Ingestor.answer(data, freshness)) == data)
        }
    }
}
