import CryptoKit
import Foundation

/// How fresh stored data is: when it was fetched, whether that's older than the integration's
/// window, and the `data_fetch` input that would refresh it. Every reader tool returns it, so
/// Dashii can tell the user how current an answer is and decide whether to fetch.
public struct Freshness: Sendable, Equatable {
    /// nil: never fetched.
    public let syncedAt: Date?
    /// Older than the integration's window, or never fetched.
    public let stale: Bool
    /// The data_fetch input that would refresh it: `{"fetcher": "...", "input": {...}}`.
    public let refresh: JSONValue?

    public init(syncedAt: Date?, maxAge: Duration, refresh: JSONValue?, now: Date = .now) {
        self.syncedAt = syncedAt
        self.refresh = refresh
        let seconds = Double(maxAge.components.seconds) + Double(maxAge.components.attoseconds) / 1e18
        stale = syncedAt.map { now.timeIntervalSince($0) > seconds } ?? true
    }

    /// `{"synced_at", "stale", "refresh"}`.
    public var json: JSONValue {
        ["synced_at": syncedAt.map { .string($0.formatted(.iso8601)) } ?? .null, "stale": .bool(stale), "refresh": refresh ?? .null]
    }
}

extension SyncedStore {
    /// Records of a kind with their freshness (`maxAge` from the integration's settings).
    public func rows(kind: String, scope: String, maxAge: Duration, refresh: (SyncedRecord) -> JSONValue?) -> [(value: JSONValue, freshness: Freshness)] {
        let now = Date.now
        return records(kind: kind, scope: scope).map { record in
            (record.value, Freshness(syncedAt: record.updatedAt, maxAge: maxAge, refresh: refresh(record), now: now))
        }
    }
}

/// What a reader tool returns when nothing is stored yet.
public func notFetched(_ fetcher: String, input: JSONValue) -> JSONValue {
    ["rows": [], "fetched": false, "hint": .string("Call data_fetch with fetcher \(fetcher)"),
     "refresh": ["fetcher": .string(fetcher), "input": input]]
}

extension JSONValue {
    /// A stable key for a fetcher's input (query-shaped data is stored under it): 16 hex
    /// characters of the SHA-256 of the input as sorted-keys JSON. Normalize the input first
    /// (trim, drop empty values) so equal questions share a key.
    public var queryKey: String {
        SHA256.hash(data: Data(jsonString().utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The value, cut to fit `bytes` of JSON when it's bigger: an array keeps the leading items
    /// that fit (`{"items", "truncated": true, "total"}`), a string its start plus a marker,
    /// anything else becomes `{"truncated": true, "json": <its JSON's start>}`. Stored records
    /// stay small (fetchers cap each one at 200 KB).
    public func capped(toBytes bytes: Int = 200_000) -> JSONValue {
        let text = jsonString()
        guard text.utf8.count > bytes else { return self }
        let marker = "…[truncated]"
        switch self {
        case .array(let items):
            var kept: [JSONValue] = []
            var size = 64
            for item in items {
                size += item.jsonString().utf8.count + 1
                if size > bytes { break }
                kept.append(item)
            }
            return ["items": .array(kept), "truncated": true, "total": .number(Double(items.count))]
        case .string(let value):
            // JSON escapes can double a string's size: keep half the budget of raw text.
            return .string(Self.prefix(value, bytes: (bytes - marker.utf8.count) / 2) + marker)
        default:
            return ["truncated": true, "json": .string(Self.prefix(text, bytes: (bytes - 64) / 2))]
        }
    }

    /// The longest start of `text` within `bytes` of UTF-8, never splitting a character.
    private static func prefix(_ text: String, bytes: Int) -> String {
        var size = 0
        var end = text.startIndex
        for index in text.indices {
            size += text[index].utf8.count
            if size > bytes { break }
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
