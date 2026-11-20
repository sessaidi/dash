import DashKit
import Foundation

/// An endpoint Ingestor fetches for a resource, described rather than coded: the path (with
/// `{field}` taken from the input), the query, where the list is in the answer, paging, and the
/// mapper that keeps what's worth storing.
///
///     IngestRoute("/repos/{repo}/actions/runs", query: ["branch": .input("branch"), "per_page": .limit("limit", default: 15, max: 50)],
///                 items: "workflow_runs", map: IngestMapper(["id": "id", "workflow": "name", "sha": .prefix("head_sha", 7)]))
public struct IngestRoute {
    /// "/repos/{repo}/pulls/{number}": each `{field}` is the input's value, percent-encoded for a path.
    public var path: String
    public var query: KeyValuePairs<String, IngestParam>
    public var headers: [String: String]
    /// Where the list is in the answer ("workflow_runs", "data.items"); nil: the answer is the
    /// list, or a single object.
    public var items: String?
    public var paging: IngestPaging?
    public var maxPages: Int
    /// Which of the list's items are kept, after `keep`.
    public var limit: IngestLimit?
    /// A failure gives the mapper an empty object instead of failing the fetch (rate limits still fail it).
    public var optional: Bool
    /// What to keep of each item (or of the object); nil: the answer as it is.
    public var map: IngestMapper?

    public init(_ path: String, query: KeyValuePairs<String, IngestParam> = [:], headers: [String: String] = [:], items: String? = nil,
                paging: IngestPaging? = nil, maxPages: Int = 10, limit: IngestLimit? = nil, optional: Bool = false, map: IngestMapper? = nil) {
        self.path = path
        self.query = query
        self.headers = headers
        self.items = items
        self.paging = paging
        self.maxPages = maxPages
        self.limit = limit
        self.optional = optional
        self.map = map
    }

    /// The path and query for this input.
    public func url(for input: JSONValue) throws -> String {
        var resolved = ""
        var rest = Substring(path)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            resolved += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            guard let value = Self.text(input[name]), !value.isEmpty else { throw ToolError("Give \(name).") }
            resolved += value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
            rest = rest[rest.index(after: close)...]
        }
        resolved += rest
        let pairs = query.compactMap { name, param in
            param.value(input).map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" }
        }
        return pairs.isEmpty ? resolved : resolved + (resolved.contains("?") ? "&" : "?") + pairs.joined(separator: "&")
    }

    /// Strings as they are, whole numbers without ".0", booleans as true/false.
    static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .bool(let flag): String(flag)
        default: nil
        }
    }

    /// The mapped answer: a list of mapped items, or the mapped object.
    func shape(_ answer: JSONValue, pagedItems: [JSONValue]?, input: JSONValue) -> JSONValue {
        let list = pagedItems ?? (items.map { answer.at($0)?.array ?? [] } ?? answer.array)
        guard var list else { return map?.map(answer, input: input) ?? answer }
        if let keep = map?.keep { list = list.filter { keep($0, input) } }
        if let limit { list = limit.apply(list) }
        return .array(list.map { map?.map($0, input: input) ?? $0 })
    }
}

/// A query parameter: a fixed value or one from the input.
public enum IngestParam: ExpressibleByStringLiteral {
    case value(String)
    /// The input's field, or `default`; left out when both are missing.
    case input(String, default: String? = nil)
    /// A count from the input, `default` when missing, at most `max`.
    case limit(String, default: Int, max: Int)
    /// Computed from the input; nil leaves it out.
    case compute((JSONValue) -> String?)

    public init(stringLiteral value: String) { self = .value(value) }

    func value(_ input: JSONValue) -> String? {
        switch self {
        case .value(let value): value
        case .input(let field, let fallback): IngestRoute.text(input[field]).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        case .limit(let field, let fallback, let max): String(min(input[field]?.int ?? fallback, max))
        case .compute(let compute): compute(input)
        }
    }
}

/// Which items of a list are kept.
public enum IngestLimit: Sendable, Equatable {
    case first(Int)
    case last(Int)

    func apply(_ list: [JSONValue]) -> [JSONValue] {
        switch self {
        case .first(let count): Array(list.prefix(count))
        case .last(let count): Array(list.suffix(count))
        }
    }
}

/// What to keep of an item: named fields, each from a path or computed. Only these are stored,
/// so answers stay small and readers see the same shape whatever the service sends.
public struct IngestMapper {
    public var fields: [String: IngestField]
    /// Items it's false for are dropped (item, input).
    public var keep: ((JSONValue, JSONValue) -> Bool)?
    /// Each item becomes this one value instead of an object (e.g. an organization's login).
    var pluck: IngestField?

    public init(_ fields: [String: IngestField], keep: ((JSONValue, JSONValue) -> Bool)? = nil) {
        self.fields = fields
        self.keep = keep
    }

    /// Each item becomes one value: `IngestMapper.pluck("login")`.
    public static func pluck(_ field: IngestField) -> IngestMapper {
        var mapper = IngestMapper([:])
        mapper.pluck = field
        return mapper
    }

    /// This mapper with more fields (or other ones under the same names).
    public func adding(_ more: [String: IngestField]) -> IngestMapper {
        var mapper = self
        mapper.fields.merge(more) { _, new in new }
        return mapper
    }

    public func map(_ item: JSONValue, input: JSONValue = [:]) -> JSONValue {
        if let pluck { return pluck.value(item, input) ?? .null }
        var object: [String: JSONValue] = [:]
        for (name, field) in fields {
            if let value = field.value(item, input) { object[name] = value }
        }
        return .object(object)
    }
}

/// Where a field comes from: a path ("number", "user.login", "labels[].name" for each element's
/// name, "run_started_at|created_at" for the first that isn't null; null when missing), or computed
/// (nil leaves the field out).
public struct IngestField: ExpressibleByStringLiteral {
    let value: (_ item: JSONValue, _ input: JSONValue) -> JSONValue?

    public init(_ value: @escaping (_ item: JSONValue, _ input: JSONValue) -> JSONValue?) { self.value = value }
    public init(stringLiteral path: String) { self = .path(path) }

    public static func path(_ path: String) -> IngestField { IngestField { item, _ in item.at(path) ?? .null } }
    /// The path's value, or `fallback` when it's missing or null.
    public static func path(_ path: String, or fallback: JSONValue) -> IngestField { IngestField { item, _ in item.at(path) ?? fallback } }
    /// Computed from the item alone.
    public static func compute(_ compute: @escaping (JSONValue) -> JSONValue?) -> IngestField { IngestField { item, _ in compute(item) } }
    public static func constant(_ value: JSONValue) -> IngestField { IngestField { _, _ in value } }
    /// True when the path has a value ("merged_at" → merged).
    public static func exists(_ path: String) -> IngestField { IngestField { item, _ in .bool(item.at(path) != nil) } }
    /// The first `count` characters of the path's text ("" when missing).
    public static func prefix(_ path: String, _ count: Int) -> IngestField {
        IngestField { item, _ in .string(String((item.at(path)?.string ?? "").prefix(count))) }
    }
    /// The first line of the path's text ("" when missing).
    public static func firstLine(_ path: String) -> IngestField {
        IngestField { item, _ in .string(String((item.at(path)?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).first ?? "")) }
    }
    /// The list at the path, each element mapped (and limited); [] when missing.
    public static func list(_ path: String, _ mapper: IngestMapper, limit: IngestLimit? = nil) -> IngestField {
        IngestField { item, input in
            var list = (item.at(path)?.array ?? []).filter { mapper.keep?($0, input) ?? true }
            if let limit { list = limit.apply(list) }
            return .array(list.map { mapper.map($0, input: input) })
        }
    }
}

extension JSONValue {
    /// The value at a dotted path: "user.login", "labels[].name" (each element's name, missing
    /// ones skipped), "a|b" (the first that isn't null); nil when missing or null.
    func at(_ path: String) -> JSONValue? {
        if path.contains("|") {
            return path.split(separator: "|").lazy.compactMap { self.at(String($0)) }.first
        }
        var value: JSONValue? = self
        let segments = path.split(separator: ".").map(String.init)
        for (index, segment) in segments.enumerated() {
            if segment.hasSuffix("[]") {
                let name = String(segment.dropLast(2))
                let list = (name.isEmpty ? value : value?[name])?.array ?? []
                let rest = segments[(index + 1)...].joined(separator: ".")
                return .array(rest.isEmpty ? list : list.compactMap { $0.at(rest) })
            }
            value = value?[segment]
        }
        if case .null = value { return nil }
        return value
    }
}
