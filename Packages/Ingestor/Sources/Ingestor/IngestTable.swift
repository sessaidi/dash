import DashKit
import Foundation
import SwiftData

/// A row of an integration's own table (`IngestTable`): a SwiftData model with typed fields its
/// widgets query (`@Query`, predicates, sorting), filled from the answers Ingestor stored.
///
///     @Model final class AcmeIssue: IngestRow {
///         var rowKey = ""
///         var item = ""
///         var syncedAt = Date.distantPast
///         var key = ""
///         var status = ""
///         init() {}
///         func update(from item: JSONValue) {
///             key = item["key"]?.string ?? ""
///             status = item["status"]?.string ?? ""
///         }
///     }
public protocol IngestRow: PersistentModel {
    /// Unique in the table: the stamped input values and the item's id ("acme/billing-api#7").
    var rowKey: String { get set }
    /// The item as stored, in JSON: unchanged items aren't written again, and fields the model
    /// doesn't map stay readable.
    var item: String { get set }
    /// When Dash fetched it.
    var syncedAt: Date { get set }
    init()
    /// Sets the typed fields from the item (which carries the stamped input fields).
    func update(from item: JSONValue)
}

/// One of an integration's tables: which resources fill it and how their items are told apart.
/// The table mirrors the cache: every item of those resources in the ingestor's scope, the
/// newest copy of each, and nothing else. It can be dropped and rebuilt at any time.
@MainActor
public struct IngestTable {
    public let name: String
    let kinds: Set<String>
    let sync: @MainActor (Ingestor, ModelContext) throws -> Void

    /// `stamp`: input fields copied onto each item and into its key (e.g. "repo"); `id`: the
    /// item's id within them (e.g. its number).
    public init<Row: IngestRow>(_ row: Row.Type, from resources: [IngestResource], stamp: [String] = [],
                                id: @escaping (JSONValue) -> String) {
        name = String(describing: row)
        kinds = Set(resources.map(\.kind))
        sync = { ingestor, context in
            let wanted = ingestor.keyedRows(resources, stamp: stamp, id: id)
            var existing: [String: Row] = [:]
            for row in try context.fetch(FetchDescriptor<Row>()) {
                if existing[row.rowKey] == nil { existing[row.rowKey] = row } else { context.delete(row) }
            }
            for (key, item, syncedAt, _) in wanted {
                let json = item.jsonString()
                if let row = existing.removeValue(forKey: key) {
                    if row.item != json {
                        row.item = json
                        row.update(from: item)
                    }
                    if row.syncedAt != syncedAt { row.syncedAt = syncedAt }
                } else {
                    let row = Row()
                    row.rowKey = key
                    row.item = json
                    row.syncedAt = syncedAt
                    row.update(from: item)
                    context.insert(row)
                }
            }
            for row in existing.values { context.delete(row) }
            if context.hasChanges { try context.save() }
        }
    }
}

/// An integration's own database file, holding its tables: `<folder>/<name>.store`, apart from
/// Dash's database. When it can't be opened (a model changed in a way SwiftData can't migrate,
/// a damaged file) it's deleted and made again empty; `isNew` says the tables need rebuilding
/// from the cache (`Ingestor.syncTables()` does it).
@MainActor
public final class IngestDatabase {
    public let name: String
    public let container: ModelContainer
    public private(set) var isNew: Bool
    /// Why the old file was replaced, when it was.
    public private(set) var replacedBecause: String?

    public var context: ModelContext { container.mainContext }

    /// ~/Library/Application Support/Dash/Ingest
    public static var folder: URL { URL.applicationSupportDirectory.appending(path: "Dash/Ingest") }

    public init(name: String, models: [any PersistentModel.Type], folder: URL? = nil, inMemory: Bool = false) throws {
        self.name = name
        let schema = Schema(models)
        if inMemory {
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true))
            isNew = true
            return
        }
        let folder = folder ?? Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name + ".store")
        let existed = FileManager.default.fileExists(atPath: url.path())
        let configuration = ModelConfiguration(name, schema: schema, url: url)
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
            isNew = !existed
        } catch {
            replacedBecause = error.localizedDescription
            Self.deleteFiles(at: url)
            container = try ModelContainer(for: schema, configurations: configuration)
            isNew = true
        }
    }

    /// The store and its SQLite side files.
    static func deleteFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
        }
    }
}

extension Ingestor {
    /// Rebuilds every table from the cache (at start, or after the database was made again).
    public func syncTables() throws {
        guard let database else { return }
        for table in tables { try table.sync(self, database.context) }
    }

    /// Updates the tables filled by `kind`.
    func syncTables(for kind: String) throws {
        guard let database else { return }
        for table in tables where table.kinds.contains(kind) { try table.sync(self, database.context) }
    }
}
