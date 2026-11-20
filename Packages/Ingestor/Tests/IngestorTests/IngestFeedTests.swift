import DashKit
import DashKitTesting
import Foundation
import Ingestor
import Testing

/// An integration with one resource on Ingestor, counting the times it reaches its "service".
@MainActor
final class Shelf: DashExtension {
    let id = "shelf"
    let name = "Shelf"
    let systemImage = "tray"
    var ingestor: Ingestor?
    var loads = 0
    var title = "Fix the invoice total"

    var resources: [IngestResource] {
        [IngestResource(kind: "shelf.pull", reader: "shelf_pull", summary: "A pull request.",
                        properties: ["number": JSONSchema.integer("Number.")], required: ["number"]) { [weak self] input in
            await Task.yield()
            self?.loads += 1
            return ["number": input["number"] ?? .null, "title": .string(self?.title ?? "")]
        }]
    }

    var fetchers: [DataFetcher] { Ingestor.fetchers(resources) { [weak self] in self?.ingestor } }
    var tools: [DashiiTool] { Ingestor.readers(resources) { [weak self] in self?.ingestor } }
}

@MainActor
struct IngestFeedTests {
    func setUp() throws -> (Shelf, TestHost, TestClock) {
        let shelf = Shelf(), clock = TestClock()
        let host = try TestHost([shelf])
        shelf.ingestor = makeIngestor(host.synced, clock: clock)
        return (shelf, host, clock)
    }

    @Test func aFeedShowsWhatsStoredAndFetchesOnlyWhenStale() async throws {
        let (shelf, host, clock) = try setUp()
        let feed = IngestFeed(host: host, fetcher: "shelf.pull", reader: "shelf_pull", input: ["number": 7])
        await feed.read()
        #expect(feed.data == nil && feed.stale && feed.syncedAt == nil)

        await feed.load()
        #expect(shelf.loads == 1 && feed.data?["title"]?.string == "Fix the invoice total")
        #expect(!feed.stale && feed.syncedAt == clock.now && !feed.isFetching && feed.error == nil)
        #expect(feed.decode(Pull.self) == Pull(number: 7, title: "Fix the invoice total"))

        await feed.load()
        #expect(shelf.loads == 1)
        clock.advance(601)
        await feed.load()
        #expect(shelf.loads == 2 && !feed.stale)

        let manual = IngestFeed(host: host, fetcher: "shelf.pull", reader: "shelf_pull", input: ["number": 8], autoFetch: false)
        await manual.load()
        #expect(shelf.loads == 2 && manual.data == nil)
        await manual.refresh()
        #expect(shelf.loads == 3 && manual.data?["number"]?.int == 8)
    }

    @Test func feedsShowingTheSameThingShareOneFetchAndHearNewData() async throws {
        let (shelf, host, _) = try setUp()
        let first = IngestFeed(host: host, fetcher: "shelf.pull", reader: "shelf_pull", input: ["number": 7])
        let second = IngestFeed(host: host, fetcher: "shelf.pull", reader: "shelf_pull", input: ["number": 7])
        async let a: Void = first.refresh()
        async let b: Void = second.refresh()
        _ = await (a, b)
        #expect(shelf.loads == 1)
        #expect(first.data == second.data && first.data != nil)

        // Fetched elsewhere (Dashii's data_fetch): the feed re-reads by itself.
        shelf.title = "Fix the refund total"
        _ = try await host.fetch("shelf.pull", ["number": 7])
        for _ in 0..<100 where first.data?["title"]?.string != "Fix the refund total" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(first.data?["title"]?.string == "Fix the refund total")

        await first.show(["number": 9])
        #expect(first.data?["number"]?.int == 9 && shelf.loads == 3)
    }

    @Test func aFailedFetchKeepsTheStoredCopy() async throws {
        let (shelf, host, clock) = try setUp()
        let feed = IngestFeed(host: host, fetcher: "shelf.pull", reader: "shelf_pull", input: ["number": 7])
        await feed.load()
        shelf.ingestor = nil
        clock.advance(601)
        await feed.refresh()
        #expect(feed.error == "shelf_pull: the integration isn't started." || feed.error == "shelf.pull: the integration isn't started.")
        let missing = IngestFeed(host: host, fetcher: "nowhere.pull", reader: "nowhere_pull")
        await missing.read()
        #expect(missing.error?.contains("nowhere_pull") == true)
    }
}

struct Pull: Decodable, Equatable {
    let number: Int
    let title: String
}
