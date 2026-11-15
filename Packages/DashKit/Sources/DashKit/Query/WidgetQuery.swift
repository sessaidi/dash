import Foundation

/// A widget's own DashQL query: the filter (and sort, take) the user or Dashii typed in its query
/// bar, without a source, e.g. `ns:bill-eu status:failing | sort -restarts | take 20`. Widgets
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
        if trimmed.hasPrefix("|") {
            query = try DashQuery.parse("rows \(trimmed)", now: now)
        } else if trimmed.lowercased().hasPrefix("where ") {
            query = try DashQuery.parse("from rows \(trimmed)", now: now)
        } else {
            // Shorthand first (`ns:prod restarts>3`); else a structured condition without `where`
            // (`assignee is null or status = Done`). The shorthand error explains best when both fail.
            do {
                query = try DashQuery.parse("rows \(trimmed)", now: now)
            } catch {
                guard let structured = try? DashQuery.parse("from rows where \(trimmed)", now: now) else { throw error }
                query = structured
            }
        }
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

    /// The query in plain words for the user ("namespace contains bill-eu · restarts over 3 ·
    /// worst restarts first · top 20"): they ask Dashii in words and read this, not DashQL.
    public var summary: String {
        query.stages.map(Self.describe).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func describe(_ stage: DashQuery.Stage) -> String {
        switch stage {
        case .filter(let expression): describe(expression)
        case .search(let text): "mentions “\(text)”"
        case .sort(let keys): "sorted by " + keys.map { "\(words($0.field))\($0.descending ? " (highest first)" : "")" }.joined(separator: ", then ")
        case .take(let count): "first \(count)"
        case .select(let fields): "showing " + fields.map { words($0.field) }.joined(separator: ", ")
        case .distinct(let fields): "one per " + fields.map(words).joined(separator: ", ")
        case .summarize(_, let by): by.isEmpty ? "summarised" : "grouped by " + by.map(words).joined(separator: ", ")
        case .join: ""
        }
    }

    static func describe(_ expression: QueryExpr) -> String {
        switch expression {
        case .and(let a, let b): "\(describe(a)) · \(describe(b))"
        case .or(let a, let b): "\(describe(a)) or \(describe(b))"
        case .not(.isNull(let field)): "has \(words(field))"
        case .not(let inner): "not (\(describe(inner)))"
        case .isNull(let field): "no \(words(field))"
        case .text(let text): "mentions “\(text)”"
        case .inList(let field, let values): "\(words(field)) is \(values.map(value).joined(separator: " or "))"
        case .between(let field, let low, let high): "\(words(field)) between \(value(low)) and \(value(high))"
        case .compare(let field, let op, let literal):
            switch op {
            case .equal: "\(words(field)) is \(value(literal))"
            case .notEqual: "\(words(field)) isn't \(value(literal))"
            case .greater: "\(words(field)) over \(value(literal))"
            case .greaterOrEqual: "\(words(field)) at least \(value(literal))"
            case .less: "\(words(field)) under \(value(literal))"
            case .lessOrEqual: "\(words(field)) at most \(value(literal))"
            case .contains: "\(words(field)) contains \(value(literal))"
            case .notContains: "\(words(field)) doesn't contain \(value(literal))"
            case .matches: "\(words(field)) matches \(value(literal))"
            }
        }
    }

    private static func words(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
    }

    private static func value(_ value: QueryValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): DashDate.number(number)
        case .bool(let flag): flag ? "yes" : "no"
        case .null: "empty"
        case .me: "me"
        case .date(let date):
            abs(date.timeIntervalSinceNow) < 86_400 * 7
                ? date.formatted(.relative(presentation: .named)) : date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// Who `me` is for widget queries; set by the host.
    @_spi(DashHost) @MainActor public static var me: [String] = []
}

extension WidgetContext {
    /// The widget's DashQL query, parsed against `fields`; nil when empty or malformed.
    public func query(fields: [QueryDataset.Field]) -> WidgetQuery? {
        try? WidgetQuery(queryText, fields: fields)
    }
}
