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

@Model
final class AcmeRun: IngestRow {
    var rowKey = ""
    var item = ""
    var syncedAt = Date.distantPast
    init() {}
    func update(from item: JSONValue) {}
}

/// A row filled by its table's mapper: the model only declares fields.
@Model
final class AcmeIssue: IngestRow {
    var rowKey = ""
    var item = ""
    var syncedAt = Date.distantPast
    var key = ""
    var status = ""
    var points = 0
    var flagged = false
    var updated: Date?
    var labels: [String] = []
    init() {}
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

    @Test func aTablesMapperFillsItsRows() async throws {
        let database = try IngestDatabase(name: "acme", models: [AcmeIssue.self], inMemory: true)
        var ingestor = makeIngestor(store, clock: clock)
        let issues = IngestResource(kind: "acme.issues", reader: "acme_issues", summary: "Issues.") { _ in
            [["key": "KAN-123", "fields": ["status": ["name": "Doing"], "points": 3, "flagged": true, "updated": "2026-11-17T09:00:00Z",
                                           "labels": ["backend", "api"]]],
             ["key": "KAN-124", "fields": ["status": ["name": "Done"]]]]
        }
        ingestor.database = database
        ingestor.tables = [IngestTable(AcmeIssue.self, from: [issues], id: "key") { row, item in
            row.key = item.string("key")
            row.status = item.string("fields.status.name")
            row.points = item.int("fields.points")
            row.flagged = item.bool("fields.flagged")
            row.updated = item.date("fields.updated")
            row.labels = item.strings("fields.labels")
        }]
        try await ingestor.fetch(issues, [:])
        let rows = try database.context.fetch(FetchDescriptor<AcmeIssue>(sortBy: [SortDescriptor(\.rowKey)]))
        #expect(rows.map(\.rowKey) == ["#KAN-123", "#KAN-124"])
        #expect(rows[0].status == "Doing" && rows[0].points == 3 && rows[0].flagged && rows[0].labels == ["backend", "api"])
        #expect(rows[0].updated == DashDate.parse("2026-11-17T09:00:00Z"))
        #expect(rows[1].status == "Done" && rows[1].points == 0 && !rows[1].flagged && rows[1].updated == nil && rows[1].labels.isEmpty)
    }

    @Test func storedDataIsCountedAndClearedWithItsTablesAndETags() async throws {
        let database = try IngestDatabase(name: "acme", models: [AcmePull.self], inMemory: true)
        let ingestor = ingestor(database)
        #expect(ingestor.summary(resources) == (0, nil) as (Int, Date?))
        service.pulls["acme/billing-api"] = [["number": 7, "title": "Fix the invoice total"], ["number": 8, "title": "Retry webhooks"]]
        try await ingestor.fetch(resources[0], ["repo": "acme/billing-api"])
        clock.advance(60)
        try await ingestor.fetch(resources[1], ["repo": "acme/billing-api", "number": 7])
        let etag = SyncedRecord(kind: IngestClient.etagKind, scope: ingestor.scope, key: "k", value: ["etag": "\"1\""], source: "acme", updatedAt: clock.now)
        let elsewhere = SyncedRecord(kind: "acme.pulls", scope: "acme:other.test", key: "k", value: [:], source: "acme", updatedAt: clock.now)
        store.upsert([etag, elsewhere])

        let summary = ingestor.summary(resources)
        #expect(summary.answers == 2 && summary.newest == clock.now && database.count(AcmePull.self) == 2)

        try ingestor.clear(resources)
        #expect(ingestor.summary(resources).answers == 0 && database.count(AcmePull.self) == 0)
        #expect(store.records(kind: IngestClient.etagKind, scope: ingestor.scope).isEmpty)
        #expect(store.records(kind: "acme.pulls", scope: "acme:other.test").count == 1)
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

    @Test func aFeatureReadsAnIntegrationsTablesWithoutChangingThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ingest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ingestor = ingestor(try IngestDatabase(name: "acme", models: [AcmePull.self], folder: folder))
        service.pulls["acme/billing-api"] = [["number": 7, "title": "Fix the invoice total"]]
        try await ingestor.fetch(resources[0], ["repo": "acme/billing-api"])

        let reader = try #require(IngestDatabase.reading(name: "acme", models: [AcmePull.self], folder: folder))
        #expect(reader.isReadOnly && !reader.isNew)
        let pulls = IngestRows(reader, FetchDescriptor<AcmePull>(sortBy: [SortDescriptor(\.rowKey)]), host: nil, fetchers: ["acme.pulls"])
        pulls.read()
        #expect(pulls.rows.map(\.title) == ["Fix the invoice total"])

        // The integration stores again: the feature's rows follow.
        service.pulls["acme/billing-api"] = [["number": 7, "title": "Fix the invoice total (v2)"], ["number": 8, "title": "Retry webhooks"]]
        try await ingestor.fetch(resources[0], ["repo": "acme/billing-api"])
        for _ in 0..<100 where pulls.rows.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pulls.rows.map(\.title) == ["Fix the invoice total (v2)", "Retry webhooks"])

        // Writes are refused.
        pulls.rows[0].title = "Changed by a feature"
        #expect(throws: (any Error).self) { try reader.context.save() }
        reader.context.rollback()

        // Another schema, or no file: nothing opened, and the integration's file stays as it is.
        #expect(IngestDatabase.reading(name: "acme", models: [AcmePull.self, AcmeRun.self], folder: folder) == nil)
        #expect(IngestDatabase.reading(name: "nowhere", models: [AcmePull.self], folder: folder) == nil)
        let reopened = try IngestDatabase(name: "acme", models: [AcmePull.self], folder: folder)
        #expect(!reopened.isNew && reopened.replacedBecause == nil)
        #expect(try rows(reopened).map(\.title) == ["Fix the invoice total (v2)", "Retry webhooks"])
    }

    @Test func rowsFetchThroughTheIntegrationOnlyWhenMissingOrStale() async throws {
        let shelf = Shelf()
        let host = try TestHost([shelf])
        let database = try IngestDatabase(name: "shelf", models: [AcmePull.self], inMemory: true)
        var ingestor = makeIngestor(host.synced, clock: clock)
        ingestor.database = database
        ingestor.tables = [IngestTable(AcmePull.self, from: shelf.resources) { "\($0["number"]?.int ?? 0)" }]
        shelf.ingestor = ingestor

        let clock = clock
        let pulls = IngestRows(database, FetchDescriptor<AcmePull>(), host: host, fetcher: "shelf.pull", input: ["number": 7])
        pulls.clock = { clock.now }
        await pulls.load()
        #expect(shelf.loads == 1 && pulls.rows.map(\.title) == ["Fix the invoice total"] && !pulls.stale && pulls.error == nil)
        await pulls.load()
        #expect(shelf.loads == 1)
        clock.advance(601)
        #expect(pulls.stale)
        await pulls.load()
        #expect(shelf.loads == 2 && !pulls.stale && !pulls.isFetching)
    }
}
