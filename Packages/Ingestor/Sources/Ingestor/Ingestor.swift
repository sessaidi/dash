import DashKit
import Foundation

/// Stores and reads one integration's answers in Dash's synced store (`host.synced`). Records are
/// kind `resource.kind` in `scope` (one per account: "github:api.github.com", a site, a
/// credentials file…), keyed by the normalized input's hash; the value keeps the input next to the
/// data. Answers are cleaned of secrets (`Sanitizer.clean`) and capped before they're stored.
///
/// A value type: build it when needed from the integration's current settings.
///
///     var ingestor: Ingestor { Ingestor(source: id, scope: "github:" + apiHost, store: host?.synced, maxAge: .seconds(freshMinutes * 60)) }
///     var fetchers: [DataFetcher] { Ingestor.fetchers(resources) { [weak self] in self?.ingestor } }
///     var tools: [DashiiTool] { Ingestor.readers(resources) { [weak self] in self?.ingestor } }
@MainActor
public struct Ingestor {
    /// The extension writing the records.
    public let source: String
    public let scope: String
    /// nil before the integration is started: fetch and read throw `notStarted`.
    public let store: (any SyncedStore)?
    /// How long answers stay fresh, unless the resource says otherwise.
    public var maxAge: Duration
    /// Query-shaped answers older than this are dropped when their kind is stored again.
    public var retention: TimeInterval = 86_400
    /// Largest stored answer, in bytes of JSON (`JSONValue.capped`).
    public var cap = 200_000
    public var clock: @MainActor () -> Date = { .now }
    /// Applied to every string of the input before it's stored and hashed: (field, trimmed value).
    /// E.g. repositories in lower case, issue keys in upper case.
    public var transform: (_ field: String, _ value: String) -> String = { $1 }
    /// Checks the normalized input (shape of ids, paths…); throw `ToolError` to refuse it.
    public var validate: (JSONValue) throws -> Void = { _ in }
    public var notStarted: String
    /// The integration's own tables, updated after each fetch of a resource that fills them.
    public var tables: [IngestTable] = []
    /// Where the tables live; nil: no tables.
    public var database: IngestDatabase?
    /// Fetches the resources that have routes; nil: not connected (`notConnected` says why).
    public var client: IngestClient?
    public var notConnected: String

    public init(source: String, scope: String, store: (any SyncedStore)?, maxAge: Duration, notStarted: String? = nil) {
        self.source = source
        self.scope = scope
        self.store = store
        self.maxAge = maxAge
        self.notStarted = notStarted ?? "\(source) isn't started."
        notConnected = "\(source) isn't connected."
    }

    // MARK: Fetchers and readers

    /// A `DataFetcher` per resource; `ingestor` is asked at each call (nil: not started).
    public static func fetchers(_ resources: [IngestResource], ingestor: @escaping @MainActor () -> Ingestor?) -> [DataFetcher] {
        resources.map { resource in
            DataFetcher(name: resource.fetcher, summary: resource.summary + " Read it with \(resource.reader).",
                        properties: resource.properties, required: resource.required) { input in
                guard let ingestor = ingestor() else { throw ToolError("\(resource.fetcher): the integration isn't started.") }
                return try await ingestor.fetch(resource, input).json
            }
        }
    }

    /// The Dashii tools that read each resource back, with its freshness.
    public static func readers(_ resources: [IngestResource], ingestor: @escaping @MainActor () -> Ingestor?) -> [DashiiTool] {
        resources.map { resource in
            DashiiTool(name: resource.reader,
                       description: resource.summary + " Reads what Dash fetched (data_fetch \(resource.fetcher)), with synced_at and stale.",
                       properties: resource.properties, required: resource.required) { input in
                guard let ingestor = ingestor() else { throw ToolError("\(resource.reader): the integration isn't started.") }
                return try ingestor.read(resource, input)
            }
        }
    }

    // MARK: Fetch and read

    /// Calls the service through the resource, stores the answer and returns the receipt.
    @discardableResult
    public func fetch(_ resource: IngestResource, _ raw: JSONValue) async throws -> IngestReceipt {
        guard let store else { throw ToolError(notStarted) }
        let input = try checkedInput(resource, raw)
        let data = Sanitizer.clean(try await load(resource, input)).capped(toBytes: cap)
        let key = input.queryKey
        let unchanged = store.record(kind: resource.kind, scope: scope, key: key)?.value["data"] == data
        let syncedAt = clock()
        store.upsert([SyncedRecord(kind: resource.kind, scope: scope, key: key, value: ["input": input, "data": data], source: source, updatedAt: syncedAt)])
        if resource.queryShaped { expire(resource.kind, before: syncedAt.addingTimeInterval(-retention)) }
        // The cache is what counts: a table that fails to update catches up at the next fetch or start.
        try? syncTables(for: resource.kind)
        IngestNotification.post(fetcher: resource.fetcher, kind: resource.kind, scope: scope, key: key)
        return IngestReceipt(stored: unchanged ? 0 : 1, unchanged: unchanged ? 1 : 0, keys: [resource.kind + "/" + key], syncedAt: syncedAt,
                             readWith: resource.reader + " " + input.jsonString())
    }

    /// The answer from the service: the resource's routes through `client`, or its `load`.
    func load(_ resource: IngestResource, _ input: JSONValue) async throws -> JSONValue {
        guard !resource.parts.isEmpty else { return try await resource.load(input) }
        guard let client else { throw ToolError(notConnected) }
        if resource.parts.count == 1, resource.parts[0].name.isEmpty { return try await client.fetch(resource.parts[0].route, input: input) }
        var answer: JSONValue = [:]
        for (name, route) in resource.parts {
            let value = try await client.fetch(route, input: input)
            answer = answer.merging(name.isEmpty ? value : .object([name: value]))
        }
        return answer
    }

    /// The stored answer with its freshness, or `notFetched` (what to fetch).
    public func read(_ resource: IngestResource, _ raw: JSONValue) throws -> JSONValue {
        guard let store else { throw ToolError(notStarted) }
        let input = try checkedInput(resource, raw)
        guard let stored = stored(resource, checked: input, in: store) else { return notFetched(resource.fetcher, input: input) }
        return Self.answer(stored.data, stored.freshness)
    }

    /// The stored answer and its freshness; nil when it was never fetched.
    public func stored(_ resource: IngestResource, _ raw: JSONValue) throws -> (data: JSONValue, freshness: Freshness)? {
        guard let store else { throw ToolError(notStarted) }
        return stored(resource, checked: try checkedInput(resource, raw), in: store)
    }

    private func stored(_ resource: IngestResource, checked input: JSONValue, in store: any SyncedStore) -> (data: JSONValue, freshness: Freshness)? {
        guard let record = store.record(kind: resource.kind, scope: scope, key: input.queryKey) else { return nil }
        let freshness = Freshness(syncedAt: record.updatedAt, maxAge: resource.maxAge ?? maxAge, refresh: resource.refresh(input), now: clock())
        return (record.value["data"] ?? .null, freshness)
    }

    /// The input, normalized and checked: required fields present, then `validate`.
    public func checkedInput(_ resource: IngestResource, _ raw: JSONValue) throws -> JSONValue {
        let input = Self.normalized(raw, properties: resource.properties, transform: transform)
        let missing = resource.required.filter { input[$0] == nil }
        if !missing.isEmpty { throw ToolError("Give \(missing.joined(separator: " and ")).") }
        try validate(input)
        return input
    }

    /// Drops the records of `kind` stored before `cutoff`.
    public func expire(_ kind: String, before cutoff: Date) {
        guard let store else { return }
        let records = store.records(kind: kind, scope: scope)
        let kept = records.filter { $0.updatedAt >= cutoff }
        if kept.count < records.count { store.replace(kind: kind, scope: scope, with: kept) }
    }

    // MARK: Stored data

    /// How many answers of these resources are stored, and when the newest was fetched.
    public func summary(_ resources: [IngestResource]) -> (answers: Int, newest: Date?) {
        guard let store else { return (0, nil) }
        let records = Set(resources.map(\.kind)).flatMap { store.records(kind: $0, scope: scope) }
        return (records.count, records.map(\.updatedAt).max())
    }

    /// Deletes every stored answer of these resources and the ETags of this scope, then empties
    /// the tables; the next fetches start afresh.
    public func clear(_ resources: [IngestResource]) throws {
        guard let store else { throw ToolError(notStarted) }
        for kind in Array(Set(resources.map(\.kind))) + [IngestClient.etagKind] { store.replace(kind: kind, scope: scope, with: []) }
        try syncTables()
    }

    // MARK: Datasets

    /// Rows for a DashQL dataset from every stored answer of these resources (lists, `items` and
    /// single objects): each item gets the input fields in `stamp` (null when absent), `synced_at`
    /// and `stale`; one row per stamp values and `id`, from the most recent fetch.
    public func rows(_ resources: [IngestResource], stamp: [String] = [], id: (JSONValue) -> String) -> [JSONValue] {
        keyedRows(resources, stamp: stamp, id: id).map { row in
            let freshness = Freshness(syncedAt: row.syncedAt, maxAge: row.maxAge, refresh: nil, now: clock())
            return row.item.merging(["synced_at": freshness.json["synced_at"] ?? .null, "stale": .bool(freshness.stale)])
        }
    }

    /// The newest copy of every item of these resources, keyed by the stamp values and `id`
    /// ("acme/billing-api#7"), sorted by key: what `rows` and the tables are built from.
    func keyedRows(_ resources: [IngestResource], stamp: [String], id: (JSONValue) -> String)
        -> [(key: String, item: JSONValue, syncedAt: Date, maxAge: Duration)] {
        guard let store else { return [] }
        var newest: [String: (item: JSONValue, at: Date, maxAge: Duration)] = [:]
        for resource in resources {
            for record in store.records(kind: resource.kind, scope: scope) {
                let input = record.value["input"] ?? [:]
                let data = record.value["data"] ?? .null
                let items = data.array ?? data["items"]?.array ?? (data.object != nil ? [data] : [])
                var fields: [String: JSONValue] = [:]
                for name in stamp { fields[name] = input[name] ?? .null }
                let prefix = stamp.map { input[$0]?.string ?? input[$0]?.jsonString() ?? "" }.joined(separator: "|")
                for item in items {
                    let key = prefix + "#" + id(item)
                    if let seen = newest[key], seen.at > record.updatedAt { continue }
                    newest[key] = (item.merging(.object(fields)), record.updatedAt, resource.maxAge ?? maxAge)
                }
            }
        }
        return newest.keys.sorted().compactMap { key in newest[key].map { (key, $0.item, $0.at, $0.maxAge) } }
    }

    // MARK: Shapes

    /// The input as stored and hashed: only the schema's properties, strings trimmed (then
    /// `transform`), empty strings and nulls dropped, so equal questions share a key.
    public nonisolated static func normalized(_ input: JSONValue, properties: [String: JSONValue],
                                              transform: (String, String) -> String = { $1 }) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (name, value) in input.object ?? [:] where properties[name] != nil {
            switch value {
            case .null: continue
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[name] = .string(transform(name, trimmed)) }
            default: result[name] = value
            }
        }
        return .object(result)
    }

    /// A reader's answer: objects get the freshness fields; lists come as `items`, anything else
    /// as `text`.
    public nonisolated static func answer(_ data: JSONValue, _ freshness: Freshness) -> JSONValue {
        switch data {
        case .object: data.merging(freshness.json)
        case .array: JSONValue.object(["items": data]).merging(freshness.json)
        default: JSONValue.object(["text": data]).merging(freshness.json)
        }
    }

    /// The data in a reader's answer, without the freshness fields (`answer`'s inverse).
    public nonisolated static func data(of answer: JSONValue) -> JSONValue {
        guard var object = answer.object else { return answer }
        for field in ["synced_at", "stale", "refresh"] { object[field] = nil }
        if object.count == 1, let items = object["items"], items.array != nil { return items }
        if object.count == 1, let text = object["text"], text.array == nil, text.object == nil { return text }
        return .object(object)
    }
}

/// Posted on the main thread after an ingestor stores an answer, so views showing it re-read.
/// By name, so every plugin's copy of Ingestor hears every other's.
public enum IngestNotification {
    public static let name = Notification.Name("DashIngestorStored")

    public static func post(fetcher: String, kind: String, scope: String, key: String) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["fetcher": fetcher, "kind": kind, "scope": scope, "key": key])
    }
}
