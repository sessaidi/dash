import Foundation

/// A widget's own DashQL query: the filter (and sort, take) the user or Dashii typed in its query
/// bar, without a source, e.g. `ns:papi-eu status:failing | sort -restarts | take 20`. Widgets
/// that declare `queryFields` get the bar and apply the query to their rows.
public struct WidgetQuery: Sendable {
    public let text: String
    let query: DashQuery
    let fields: [QueryDataset.Field]

    /// nil for an empty query; throws a `QueryError` for a malformed one.
    public init?(_ text: String, fields: [QueryDataset.Field], now: Date = .now) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.text = trimmed
        self.fields = fields
        // The widget is the source: the query starts with its filter (or a stage after `|`).
        let source = trimmed.hasPrefix("|") ? "rows \(trimmed)" : (trimmed.lowercased().hasPrefix("where ") ? "from rows \(trimmed)" : "rows \(trimmed)")
        query = try DashQuery.parse(source, now: now)
        if case .join? = query.stages.first(where: { if case .join = $0 { true } else { false } }) {
            throw QueryError("A widget's query can't join; use dashql for that.")
        }
    }

    /// The rows the widget shows: filtered, sorted and cut as the query says.
    @MainActor
    public func apply(to rows: [JSONValue]) async -> [JSONValue] {
        let dataset = QueryDataset(name: "rows", summary: "", fields: fields) { _ in rows }
        return (try? await QueryEngine(datasets: [dataset], me: WidgetQuery.me).run(query).rows) ?? rows
    }

    /// Typed items kept in order: each is turned into a row (with an `index`) to run the query.
    @MainActor
    public func apply<Item>(to items: [Item], row: (Item) -> JSONValue) async -> [Item] {
        let rows = items.enumerated().map { index, item -> JSONValue in
            guard case .object(var fields) = row(item) else { return ["__index": .number(Double(index))] }
            fields["__index"] = .number(Double(index))
            return .object(fields)
        }
        return await apply(to: rows).compactMap { $0["__index"]?.int }.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// Who `me` is for widget queries; set by the host.
    @MainActor public static var me: [String] = []
}

extension WidgetContext {
    /// The widget's DashQL query, parsed against `fields`; nil when empty or malformed.
    public func query(fields: [QueryDataset.Field]) -> WidgetQuery? {
        try? WidgetQuery(queryText, fields: fields)
    }
}
