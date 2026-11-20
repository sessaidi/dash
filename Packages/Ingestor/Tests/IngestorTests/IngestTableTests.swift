import DashKit
import DashKitTesting
import Foundation
import Ingestor
import SwiftData
import Testing

@Model
final class AcmePull: IngestRow {
    var rowKey = ""
    var item = ""
    var syncedAt = Date.distantPast
    var repo = ""
    var number = 0
    var title = ""
    var updates = 0

    init() {}

    func update(from item: JSONValue) {
        repo = item["repo"]?.string ?? ""
        number = item["number"]?.int ?? 0
        title = item["title"]?.string ?? ""
        updates += 1
    }
}

/// An integration's own tables: filled from what the ingestor stored, the newest copy of each
/// item, rows dropped with their answers, rebuilt from the cache when the file is made again.
@MainActor
struct IngestTableTests {
    /// What the "service" answers: the open pull requests per repository.
    final class Service {
        var pulls: [String: [JSONValue]] = [:]
    }

    let service = Service()
    let store = MemorySyncedStore()
    let clock = TestClock()

    var resources: [IngestResource] {
        let service = service
        return [
            IngestResource(kind: "acme.pulls", reader: "acme_pulls", summary: "Open pull requests.", properties: ["repo": JSONSchema.string("owner/name")],
                           required: ["repo"]) { input in .array(service.pulls[input["repo"]?.string ?? ""] ?? []) },
            IngestResource(kind: "acme.pull", reader: "acme_pull", summary: "One pull request.",
                           properties: ["repo": JSONSchema.string("owner/name"), "number": JSONSchema.integer("Number")],
                           required: ["repo", "number"]) { input in
                service.pulls[input["repo"]?.string ?? ""]?.first { $0["number"] == input["number"] } ?? ["number": input["number"] ?? .null, "title": "Closed"]
            },
        ]
    }

    func ingestor(_ database: IngestDatabase) -> Ingestor {
        var ingestor = makeIngestor(store, clock: clock)
        ingestor.database = database
        ingestor.tables = [IngestTable(AcmePull.self, from: resources, stamp: ["repo"]) { "\($0["number"]?.int ?? 0)" }]
        return ingestor
    }

    func rows(_ database: IngestDatabase) throws -> [AcmePull] {
        try database.context.fetch(FetchDescriptor<AcmePull>(sortBy: [SortDescriptor(\.rowKey)]))
    }

    @Test func fetchesFillTheTableWithTheNewestCopyOfEachItem() async throws {
        let database = try IngestDatabase(name: "acme", models: [AcmePull.self], inMemory: true)
        let ingestor = ingestor(database)
        service.pulls["acme/billing-api"] = [["number": 7, "title": "Fix the invoice total"], ["number": 8, "title": "Retry webhooks"]]
        service.pulls["acme/ledger"] = [["number": 7, "title": "Round cents"]]

        try await ingestor.fetch(resources[0], ["repo": "acme/billing-api"])
        try await ingestor.fetch(resources[0], ["repo": "acme/ledger"])
        #expect(try rows(database).map(\.rowKey) == ["acme/billing-api#7", "acme/billing-api#8", "acme/ledger#7"])
        #expect(try rows(database).map(\.title) == ["Fix the invoice total", "Retry webhooks", "Round cents"])
        #expect(try rows(database).allSatisfy { $0.repo.hasPrefix("acme/") && $0.syncedAt == clock.now && $0.updates == 1 })

        // One pull request fetched later wins over the list's copy; the others aren't rewritten.
        clock.advance(60)
        service.pulls["acme/billing-api"]?[0] = ["number": 7, "title": "Fix the invoice total (v2)"]
        try await ingestor.fetch(resources[1], ["repo": "acme/billing-api", "number": 7])
        let pulls = try rows(database)
        #expect(pulls[0].title == "Fix the invoice total (v2)" && pulls[0].updates == 2 && pulls[0].syncedAt == clock.now)
        #expect(pulls[1].updates == 1 && pulls[2].updates == 1)

        // Fetching the same list again changes nothing but when it was synced.
        clock.advance(60)
        try await ingestor.fetch(resources[0], ["repo": "acme/ledger"])
        #expect(try rows(database).last.map { $0.updates == 1 && $0.syncedAt == clock.now } == true)
    }

    @Test func rowsGoWhenTheirAnswersDo() async throws {
        let database = try IngestDatabase(name: "acme", models: [AcmePull.self], inMemory: true)
        let ingestor = ingestor(database)
        service.pulls["acme/billing-api"] = [["number": 7, "title": "Fix the invoice total"]]
        try await ingestor.fetch(resources[0], ["repo": "acme/billing-api"])
        #expect(try rows(database).count == 1)

        store.replace(kind: "acme.pulls", scope: ingestor.scope, with: [])
        try ingestor.syncTables()
        #expect(try rows(database).isEmpty)
    }

    @Test func aDatabaseThatCantBeOpenedIsMadeAgainAndRebuiltFromTheCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ingest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        service.pulls["acme/billing-api"] = [["number": 7, "title": "Fix the invoice total"]]

        let first = try IngestDatabase(name: "acme", models: [AcmePull.self], folder: folder)
        #expect(first.isNew && first.replacedBecause == nil)
        try await ingestor(first).fetch(resources[0], ["repo": "acme/billing-api"])

        let reopened = try IngestDatabase(name: "acme", models: [AcmePull.self], folder: folder)
        #expect(!reopened.isNew && reopened.replacedBecause == nil)
        #expect(try rows(reopened).map(\.title) == ["Fix the invoice total"])

        try Data("not a database".utf8).write(to: folder.appending(path: "acme.store"))
        for side in ["acme.store-wal", "acme.store-shm"] { try? FileManager.default.removeItem(at: folder.appending(path: side)) }
        let replaced = try IngestDatabase(name: "acme", models: [AcmePull.self], folder: folder)
        #expect(replaced.isNew && replaced.replacedBecause != nil)
        #expect(try rows(replaced).isEmpty)
        try ingestor(replaced).syncTables()
        #expect(try rows(replaced).map(\.rowKey) == ["acme/billing-api#7"])
    }
}
