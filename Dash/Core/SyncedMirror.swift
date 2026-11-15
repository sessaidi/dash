import DashKit
import Foundation
import SwiftData

/// One mirrored record in the store (`SyncedRecord` for extensions).
@Model
final class SyncedRecordModel {
    /// kind, scope and key joined: unique.
    @Attribute(.unique) var id: String
    var kind: String
    var scope: String
    var key: String
    var valueData: Data
    var source: String
    var updatedAt: Date

    init(_ record: SyncedRecord) {
        id = Self.id(record.kind, record.scope, record.key)
        kind = record.kind
        scope = record.scope
        key = record.key
        valueData = Data(record.value.jsonString().utf8)
        source = record.source
        updatedAt = record.updatedAt
    }

    static func id(_ kind: String, _ scope: String, _ key: String) -> String { kind + "\u{1f}" + scope + "\u{1f}" + key }

    var record: SyncedRecord {
        SyncedRecord(kind: kind, scope: scope, key: key, value: (try? JSONValue.parse(valueData)) ?? .null, source: source, updatedAt: updatedAt)
    }
}

/// The mirror of online data in Dash's store. Sync times live in the same table, as
/// "sync.time" records keyed by the synced kind.
@MainActor
final class SyncedMirror: SyncedStore {
    private unowned let host: ExtensionHost

    init(host: ExtensionHost) {
        self.host = host
    }

    private var context: ModelContext { host.context }

    func records(kind: String, scope: String) -> [SyncedRecord] {
        let descriptor = FetchDescriptor<SyncedRecordModel>(predicate: #Predicate { $0.kind == kind && $0.scope == scope }, sortBy: [SortDescriptor(\.key)])
        return ((try? context.fetch(descriptor)) ?? []).map(\.record)
    }

    func record(kind: String, scope: String, key: String) -> SyncedRecord? {
        let id = SyncedRecordModel.id(kind, scope, key)
        return (try? context.fetch(FetchDescriptor<SyncedRecordModel>(predicate: #Predicate { $0.id == id })))?.first?.record
    }

    func upsert(_ records: [SyncedRecord]) {
        guard !records.isEmpty else { return }
        let ids = records.map { SyncedRecordModel.id($0.kind, $0.scope, $0.key) }
        let existing = Dictionary(((try? context.fetch(FetchDescriptor<SyncedRecordModel>(predicate: #Predicate { ids.contains($0.id) }))) ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        for record in records {
            if let model = existing[SyncedRecordModel.id(record.kind, record.scope, record.key)] {
                model.valueData = Data(record.value.jsonString().utf8)
                model.source = record.source
                model.updatedAt = record.updatedAt
            } else {
                context.insert(SyncedRecordModel(record))
            }
        }
        try? context.save()
    }

    func replace(kind: String, scope: String, with records: [SyncedRecord]) {
        let keep = Set(records.map(\.key))
        for model in (try? context.fetch(FetchDescriptor<SyncedRecordModel>(predicate: #Predicate { $0.kind == kind && $0.scope == scope }))) ?? []
        where !keep.contains(model.key) {
            context.delete(model)
        }
        upsert(records + [SyncedRecord(kind: "sync.time", scope: scope, key: kind, value: .string(Date.now.formatted(.iso8601)), source: "dash")])
    }

    func lastSynced(kind: String, scope: String) -> Date? {
        record(kind: "sync.time", scope: scope, key: kind)?.updatedAt
    }
}
