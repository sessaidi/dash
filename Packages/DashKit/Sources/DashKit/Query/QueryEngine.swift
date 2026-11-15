import Foundation

/// Something DashQL can read from: rows of JSON objects, described by their fields.
public struct QueryDataset: Sendable {
    public struct Field: Sendable, Equatable {
        public let name: String
        /// string, number, date, bool, list, object.
        public let type: String
        public let summary: String
        /// Shorter names accepted in queries (`ns` for `namespace`).
        public let aliases: [String]

        public init(_ name: String, _ type: String = "string", _ summary: String = "", aliases: [String] = []) {
            self.name = name
            self.type = type
            self.summary = summary
            self.aliases = aliases
        }
    }

    public let name: String
    public let summary: String
    public let fields: [Field]
    /// Whether it takes an argument (`from widget "Failing pods"`), and what it means.
    public let argument: String?
    /// The rows, read fresh (async: datasets may sync first or read a store).
    public let rows: @MainActor @Sendable (_ argument: String?) async throws -> [JSONValue]

    public init(name: String, summary: String, fields: [Field] = [], argument: String? = nil,
                rows: @escaping @MainActor @Sendable (_ argument: String?) async throws -> [JSONValue]) {
        self.name = name.lowercased()
        self.summary = summary
        self.fields = fields
        self.argument = argument
        self.rows = rows
    }

    public var schema: JSONValue {
        ["name": .string(name), "summary": .string(summary), "argument": argument.map(JSONValue.string) ?? .null,
         "fields": .array(fields.map { ["name": .string($0.name), "type": .string($0.type), "summary": .string($0.summary),
                                         "aliases": .array($0.aliases.map(JSONValue.string))] })]
    }

    /// A field's real name for an alias, or the name itself.
    func resolve(_ name: String) -> String {
        let lower = name.lowercased()
        return fields.first { $0.name.lowercased() == lower || $0.aliases.contains { $0.lowercased() == lower } }?.name ?? name
    }
}

/// Runs DashQL over datasets.
@MainActor
public struct QueryEngine {
    public var datasets: [QueryDataset]
    /// Who `me` is (names, emails, logins): a value matches `me` when it equals any of them.
    public var me: [String]
    public var now: Date
    /// Rows a query may return at most (more are cut, and `truncated` says so).
    public var maxRows = 500

    public init(datasets: [QueryDataset], me: [String] = [], now: Date = .now) {
        self.datasets = datasets
        self.me = me
        self.now = now
    }

    public struct Result: Sendable {
        public var rows: [JSONValue]
        public var total: Int
        public var truncated: Bool
        public var json: JSONValue {
            ["rows": .array(rows), "count": .number(Double(rows.count)), "total": .number(Double(total)), "truncated": .bool(truncated)]
        }
    }

    public func run(_ text: String) async throws -> Result {
        try await run(DashQuery.parse(text, now: now))
    }

    public func run(_ query: DashQuery) async throws -> Result {
        let dataset = try dataset(query.source.dataset)
        var rows = try await dataset.rows(query.source.argument)
        var current = dataset
        for stage in query.stages {
            switch stage {
            case .filter(let expression):
                let resolved = resolveFields(expression, in: current)
                rows = rows.filter { matches(resolved, $0) }
            case .search(let text):
                rows = rows.filter { matches(.text(text), $0) }
            case .sort(let keys):
                let keys = keys.map { DashQuery.SortKey(field: current.resolve($0.field), descending: $0.descending) }
                rows.sort { a, b in
                    for key in keys {
                        let order = Self.compare(a.value(at: key.field), b.value(at: key.field))
                        if order != .orderedSame { return key.descending ? order == .orderedDescending : order == .orderedAscending }
                    }
                    return false
                }
            case .take(let count):
                rows = Array(rows.prefix(count))
            case .select(let projections):
                rows = rows.map { row in
                    .object(Dictionary(projections.map { ($0.alias ?? $0.field, row.value(at: current.resolve($0.field)) ?? .null) }) { first, _ in first })
                }
            case .distinct(let fields):
                var seen: Set<String> = []
                let fields = fields.map(current.resolve)
                rows = rows.filter { row in seen.insert(fields.map { row.value(at: $0)?.jsonString() ?? "null" }.joined(separator: "\u{1F}")).inserted }
                if fields.count == 1 { rows = rows.map { [fields[0]: $0.value(at: fields[0]) ?? .null] } }
            case .summarize(let aggregates, let by):
                rows = summarize(rows, aggregates: aggregates.map { aggregate in
                    var aggregate = aggregate
                    aggregate.field = aggregate.field.map(current.resolve)
                    return aggregate
                }, by: by.map(current.resolve))
                current = QueryDataset(name: current.name, summary: current.summary) { _ in [] }
            case .join(let source, let left, let right, let alias):
                let other = try self.dataset(source.dataset)
                let otherRows = try await other.rows(source.argument)
                let leftField = current.resolve(left), rightField = other.resolve(right)
                var index: [String: [JSONValue]] = [:]
                for row in otherRows {
                    for key in Self.keys(row.value(at: rightField)) { index[key, default: []].append(row) }
                }
                rows = rows.map { row in
                    var matched: [JSONValue] = []
                    for key in Self.keys(row.value(at: leftField)) { matched += index[key] ?? [] }
                    guard case .object(var fields) = row else { return row }
                    fields[alias] = .array(matched)
                    return .object(fields)
                }
            }
        }
        let total = rows.count
        return Result(rows: Array(rows.prefix(maxRows)), total: total, truncated: total > maxRows)
    }

    func dataset(_ name: String) throws -> QueryDataset {
        let lower = name.lowercased()
        if let found = datasets.first(where: { $0.name == lower }) ?? datasets.first(where: { $0.name.hasPrefix(lower) || $0.name.hasSuffix("." + lower) }) {
            return found
        }
        throw QueryError("No dataset `\(name)`. Datasets: \(datasets.map(\.name).sorted().joined(separator: ", ")).")
    }

    // MARK: Matching

    private func resolveFields(_ expression: QueryExpr, in dataset: QueryDataset) -> QueryExpr {
        switch expression {
        case .and(let a, let b): .and(resolveFields(a, in: dataset), resolveFields(b, in: dataset))
        case .or(let a, let b): .or(resolveFields(a, in: dataset), resolveFields(b, in: dataset))
        case .not(let a): .not(resolveFields(a, in: dataset))
        case .compare(let field, let op, let value): .compare(dataset.resolve(field), op, value)
        case .inList(let field, let values): .inList(dataset.resolve(field), values)
        case .between(let field, let low, let high): .between(dataset.resolve(field), low, high)
        case .isNull(let field): .isNull(dataset.resolve(field))
        case .text: expression
        }
    }

    func matches(_ expression: QueryExpr, _ row: JSONValue) -> Bool {
        switch expression {
        case .and(let a, let b): return matches(a, row) && matches(b, row)
        case .or(let a, let b): return matches(a, row) || matches(b, row)
        case .not(let a): return !matches(a, row)
        case .isNull(let field):
            let value = row.value(at: field)
            return value == nil || value == .null
        case .text(let text):
            return row.jsonString().localizedCaseInsensitiveContains(text)
        case .inList(let field, let values):
            return values.contains { compare(row.value(at: field), .equal, $0) }
        case .between(let field, let low, let high):
            return compare(row.value(at: field), .greaterOrEqual, low) && compare(row.value(at: field), .lessOrEqual, high)
        case .compare(let field, let op, let value):
            return compare(row.value(at: field), op, value)
        }
    }

    /// One field value against a literal. Lists match when any element does.
    func compare(_ actual: JSONValue?, _ op: QueryExpr.Comparison, _ expected: QueryValue) -> Bool {
        if case .array(let items)? = actual, op != .notEqual, op != .notContains {
            return items.contains { compare($0, op, expected) }
        }
        if case .me = expected {
            let text = actual.flatMap(Self.text) ?? ""
            let hit = me.contains { !text.isEmpty && ($0.caseInsensitiveCompare(text) == .orderedSame || (op == .contains && text.localizedCaseInsensitiveContains($0))) }
            return op == .notEqual || op == .notContains ? !hit : hit
        }
        if case .null = expected {
            let isNull = actual == nil || actual == .null
            return op == .notEqual ? !isNull : isNull
        }
        guard let actual, actual != .null else { return op == .notEqual || op == .notContains }
        switch op {
        case .contains, .notContains:
            let hit = (Self.text(actual) ?? actual.jsonString()).localizedCaseInsensitiveContains(Self.text(expected))
            return op == .contains ? hit : !hit
        case .matches:
            guard let regex = try? Regex(Self.text(expected)).ignoresCase() else { return false }
            return (Self.text(actual) ?? actual.jsonString()).contains(regex)
        default:
            let order = Self.order(actual, expected)
            switch op {
            case .equal: return order == .orderedSame
            case .notEqual: return order != .orderedSame
            case .greater: return order == .orderedDescending
            case .greaterOrEqual: return order != .orderedAscending && order != nil
            case .less: return order == .orderedAscending
            case .lessOrEqual: return order != .orderedDescending && order != nil
            default: return false
            }
        }
    }

    /// How a row value compares to a literal: by date, number, bool, else text (case-insensitive).
    static func order(_ actual: JSONValue, _ expected: QueryValue) -> ComparisonResult? {
        switch expected {
        case .date(let moment):
            guard let value = Self.date(actual) else { return nil }
            return value == moment ? .orderedSame : value < moment ? .orderedAscending : .orderedDescending
        case .number(let number):
            guard let value = actual.double ?? Self.text(actual).flatMap(Double.init) else { return nil }
            return value == number ? .orderedSame : value < number ? .orderedAscending : .orderedDescending
        case .bool(let flag):
            guard case .bool(let value) = actual else { return nil }
            return value == flag ? .orderedSame : .orderedAscending
        case .string(let text):
            guard let value = Self.text(actual) else { return nil }
            return value.caseInsensitiveCompare(text)
        case .null, .me:
            return nil
        }
    }

    /// For sorting rows: numbers, then dates, then text; missing values last.
    static func compare(_ a: JSONValue?, _ b: JSONValue?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil), (.null?, .null?): return .orderedSame
        case (nil, _), (.null?, _): return .orderedDescending
        case (_, nil), (_, .null?): return .orderedAscending
        case (let a?, let b?):
            if let x = a.double, let y = b.double { return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending }
            if let x = date(a), let y = date(b) { return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending }
            return (text(a) ?? a.jsonString()).localizedStandardCompare(text(b) ?? b.jsonString())
        }
    }

    static func text(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): number.rounded() == number ? String(Int(number)) : String(number)
        case .bool(let flag): String(flag)
        default: nil
        }
    }

    static func text(_ value: QueryValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): number.rounded() == number ? String(Int(number)) : String(number)
        case .bool(let flag): String(flag)
        case .date(let date): date.formatted(.iso8601)
        case .null: "null"
        case .me: "me"
        }
    }

    /// A row value as a date: ISO 8601 text, or seconds since 1970.
    static func date(_ value: JSONValue) -> Date? {
        switch value {
        case .string(let text):
            return ISO8601DateFormatter().date(from: text)
                ?? (try? Date(text, strategy: .iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeSeparator(.colon)))
                ?? QueryLexer.day(String(text.prefix(10)))
        case .number(let seconds) where seconds > 1_000_000_000:
            return Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1000 : seconds)
        default:
            return nil
        }
    }

    /// Join keys: a value's text, or each element's for a list (case-insensitive).
    static func keys(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let items)?: items.flatMap { keys($0) }
        case let value?: text(value).map { [$0.lowercased()] } ?? []
        case nil: []
        }
    }

    // MARK: Summaries

    private func summarize(_ rows: [JSONValue], aggregates: [DashQuery.Aggregate], by: [String]) -> [JSONValue] {
        var groups: [String: (key: [String: JSONValue], rows: [JSONValue])] = [:]
        var order: [String] = []
        for row in rows {
            let key = Dictionary(by.map { ($0, row.value(at: $0) ?? .null) }) { first, _ in first }
            let id = by.map { key[$0]?.jsonString() ?? "null" }.joined(separator: "\u{1F}")
            if groups[id] == nil { order.append(id); groups[id] = (key, []) }
            groups[id]?.rows.append(row)
        }
        if by.isEmpty, groups.isEmpty { groups[""] = ([:], []); order = [""] }
        return order.compactMap { groups[$0] }.map { group in
            var fields = group.key
            for aggregate in aggregates {
                let values = aggregate.field.map { field in group.rows.compactMap { $0.value(at: field) }.filter { $0 != .null } } ?? []
                let numbers = values.compactMap { $0.double ?? Self.text($0).flatMap(Double.init) }
                let result: JSONValue
                switch aggregate.function {
                case .count: result = .number(Double(aggregate.field == nil ? group.rows.count : values.count))
                case .sum: result = .number(numbers.reduce(0, +))
                case .avg: result = numbers.isEmpty ? .null : .number(numbers.reduce(0, +) / Double(numbers.count))
                case .min: result = values.min { Self.compare($0, $1) == .orderedAscending } ?? .null
                case .max: result = values.max { Self.compare($0, $1) == .orderedAscending } ?? .null
                case .distinct: result = .number(Double(Set(values.map { $0.jsonString() }).count))
                }
                fields[aggregate.name] = result
            }
            return .object(fields)
        }
        .sorted { a, b in (a["count"]?.double ?? 0) > (b["count"]?.double ?? 0) }
    }
}

extension JSONValue {
    /// A dotted path (`assignee.name`, `labels`); through arrays of objects it collects each element's value.
    public func value(at path: String) -> JSONValue? {
        var current: JSONValue? = self
        for part in path.split(separator: ".").map(String.init) {
            switch current {
            case .object(let fields)?:
                current = fields[part] ?? fields.first { $0.key.caseInsensitiveCompare(part) == .orderedSame }?.value
            case .array(let items)?:
                let values = items.compactMap { $0.value(at: part) }
                current = values.isEmpty ? nil : .array(values)
            default:
                return nil
            }
        }
        return current
    }
}
