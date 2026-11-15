import Foundation

/// One record of online data mirrored on this Mac: a tag of a GitHub repository, a commit range,
/// an issue… Integrations fetch from their service and write records; features and widgets read
/// them. Online is the source of truth: the mirror is refreshed from it and never edited locally.
public struct SyncedRecord: Sendable, Equatable {
    /// What it is: "git.tag", "git.range", "git.repo"…
    public let kind: String
    /// Whose it is: "github:owner/name", "gitlab:group/project"…
    public let scope: String
    /// Unique within kind and scope: a tag name, "base...head"…
    public let key: String
    public var value: JSONValue
    /// The extension that wrote it.
    public var source: String
    public var updatedAt: Date

    public init(kind: String, scope: String, key: String, value: JSONValue, source: String, updatedAt: Date = .now) {
        self.kind = kind
        self.scope = scope
        self.key = key
        self.value = value
        self.source = source
        self.updatedAt = updatedAt
    }
}

/// The mirror of online data, shared by every extension (`ExtensionContext.synced`).
@MainActor
public protocol SyncedStore: AnyObject {
    func records(kind: String, scope: String) -> [SyncedRecord]
    func record(kind: String, scope: String, key: String) -> SyncedRecord?
    /// Adds or replaces these records (by kind, scope and key).
    func upsert(_ records: [SyncedRecord])
    /// Makes the mirror of `kind` in `scope` exactly `records`: what the service no longer has
    /// is removed, because online is the source of truth.
    func replace(kind: String, scope: String, with records: [SyncedRecord])
    /// When `kind` in `scope` was last synced (set by `replace`), nil if never.
    func lastSynced(kind: String, scope: String) -> Date?
}

/// An in-memory mirror: for hosts that don't persist one (test fakes) and for tests.
@MainActor
public final class MemorySyncedStore: SyncedStore {
    private var storage: [String: SyncedRecord] = [:]
    private var synced: [String: Date] = [:]

    public init() {}

    private static func id(_ kind: String, _ scope: String, _ key: String) -> String { kind + "\u{1f}" + scope + "\u{1f}" + key }

    public func records(kind: String, scope: String) -> [SyncedRecord] {
        storage.values.filter { $0.kind == kind && $0.scope == scope }.sorted { $0.key < $1.key }
    }

    public func record(kind: String, scope: String, key: String) -> SyncedRecord? { storage[Self.id(kind, scope, key)] }

    public func upsert(_ records: [SyncedRecord]) {
        for record in records { storage[Self.id(record.kind, record.scope, record.key)] = record }
    }

    public func replace(kind: String, scope: String, with records: [SyncedRecord]) {
        storage = storage.filter { !($0.value.kind == kind && $0.value.scope == scope) }
        upsert(records)
        synced[kind + "\u{1f}" + scope] = .now
    }

    public func lastSynced(kind: String, scope: String) -> Date? { synced[kind + "\u{1f}" + scope] }
}

@MainActor
enum DefaultSynced {
    static let store = MemorySyncedStore()
}
