import DashKit
import Foundation

/// Something an integration fetches from its service and Dash reads back: the fetcher `fetcher`
/// calls the service and stores the compact answer under `kind`; the reader `reader` (same input)
/// returns it with its freshness, or says what to fetch.
@MainActor
public struct IngestResource {
    /// Where answers are stored, e.g. "github.pull".
    public let kind: String
    /// The `data_fetch` name, e.g. "github.pull".
    public let fetcher: String
    /// The Dashii tool that reads it back, e.g. "github_pull".
    public let reader: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    public let summary: String
    public let properties: [String: JSONValue]
    public let required: [String]
    /// Answers to a query (filtered lists, searches, raw paths): dropped after the ingestor's
    /// retention once the kind is stored again.
    public var queryShaped: Bool
    /// How long an answer stays fresh; nil: the ingestor's `maxAge`.
    public var maxAge: Duration?
    /// Calls the service with the checked input; returns the compact answer to store. Unused
    /// when the resource has routes.
    public let load: @MainActor (JSONValue) async throws -> JSONValue
    /// The routes the ingestor fetches with its client: one unnamed route is the answer; named
    /// ones make an object of their answers (an unnamed one among them is merged into it).
    public let parts: [(name: String, route: IngestRoute)]

    /// A resource the integration fetches itself (several calls, text, decoding…).
    public init(kind: String, fetcher: String? = nil, reader: String, summary: String, properties: [String: JSONValue] = [:],
                required: [String] = [], queryShaped: Bool = false, maxAge: Duration? = nil,
                load: @escaping @MainActor (JSONValue) async throws -> JSONValue) {
        self.kind = kind
        self.fetcher = fetcher ?? kind
        self.reader = reader
        self.summary = summary
        self.properties = properties
        self.required = required
        self.queryShaped = queryShaped
        self.maxAge = maxAge
        self.load = load
        parts = []
    }

    /// A resource the ingestor fetches from one route.
    public init(kind: String, fetcher: String? = nil, reader: String, summary: String, properties: [String: JSONValue] = [:],
                required: [String] = [], queryShaped: Bool = false, maxAge: Duration? = nil, route: IngestRoute) {
        self.init(kind: kind, fetcher: fetcher, reader: reader, summary: summary, properties: properties, required: required,
                  queryShaped: queryShaped, maxAge: maxAge, parts: ["": route])
    }

    /// A resource the ingestor fetches from several routes, one after the other.
    public init(kind: String, fetcher: String? = nil, reader: String, summary: String, properties: [String: JSONValue] = [:],
                required: [String] = [], queryShaped: Bool = false, maxAge: Duration? = nil, parts: KeyValuePairs<String, IngestRoute>) {
        self.kind = kind
        self.fetcher = fetcher ?? kind
        self.reader = reader
        self.summary = summary
        self.properties = properties
        self.required = required
        self.queryShaped = queryShaped
        self.maxAge = maxAge
        self.parts = parts.map { ($0.key, $0.value) }
        let fetcher = self.fetcher
        load = { _ in throw ToolError("\(fetcher) is fetched by its ingestor.") }
    }

    /// The data_fetch input that refreshes the answer to `input`.
    public func refresh(_ input: JSONValue) -> JSONValue { ["fetcher": .string(fetcher), "input": input] }
}

/// What a fetcher answers: what it stored and where to read it.
public struct IngestReceipt: Sendable, Equatable {
    public var stored: Int
    public var unchanged: Int
    /// "<kind>/<key>" of every record written.
    public var keys: [String]
    public var syncedAt: Date
    /// The reader call that returns it: "github_pull {\"number\":1,\"repo\":\"acme/billing-api\"}".
    public var readWith: String
    /// Extra fields for the receipt ("pages": 3…).
    public var extra: [String: JSONValue]

    public init(stored: Int, unchanged: Int, keys: [String], syncedAt: Date, readWith: String, extra: [String: JSONValue] = [:]) {
        self.stored = stored
        self.unchanged = unchanged
        self.keys = keys
        self.syncedAt = syncedAt
        self.readWith = readWith
        self.extra = extra
    }

    /// `{stored, unchanged, keys, synced_at, read_with}` plus `extra`.
    public var json: JSONValue {
        JSONValue.object(extra).merging([
            "stored": .number(Double(stored)), "unchanged": .number(Double(unchanged)), "keys": .array(keys.map(JSONValue.string)),
            "synced_at": .string(syncedAt.formatted(.iso8601)), "read_with": .string(readWith),
        ])
    }
}
