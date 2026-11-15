import Foundation

/// DashQL: one query language for Dashii, agents and widgets to read, filter, join and
/// summarise whatever Dash knows: pods, tickets, PRs, releases, activity, notes, any widget's
/// live data. A query is a source followed by stages:
///
///     from pods | where namespace = "papi-eu" and restarts > 3 | sort -restarts | take 10
///     pods ns:papi-eu status:failing restarts>3            (shorthand for the same kind of filter)
///     from jira where assignee = me | join prs on key = ticket | select key, summary, prs.title
///     from activity where time > -24h | count by source
///     from widget "Failing pods" | where restarts > 5
///
/// It only reads: no stage changes anything.
public struct DashQuery: Equatable, Sendable {
    public var source: Source
    public var stages: [Stage]

    public struct Source: Equatable, Sendable {
        /// A dataset name ("pods", "jira", "widget").
        public var dataset: String
        /// For datasets that take one (`from widget "Failing pods"`).
        public var argument: String?
    }

    public indirect enum Stage: Equatable, Sendable {
        case filter(QueryExpr)
        case search(String)
        case sort([SortKey])
        case take(Int)
        case select([Projection])
        case distinct([String])
        /// `count by a, b` or `summarize count(), avg(x) as mean by a`.
        case summarize([Aggregate], by: [String])
        /// `join prs on key = ticket [as alias]`: adds the matching rows of another dataset under
        /// `alias` (an array; empty when none match: a left join).
        case join(Source, left: String, right: String, alias: String)
    }

    public struct SortKey: Equatable, Sendable {
        public var field: String
        public var descending: Bool
    }

    public struct Projection: Equatable, Sendable {
        public var field: String
        public var alias: String?
    }

    public struct Aggregate: Equatable, Sendable {
        public enum Function: String, Sendable, CaseIterable { case count, sum, avg, min, max, distinct }
        public var function: Function
        public var field: String?
        public var alias: String?

        public var name: String { alias ?? (field.map { "\(function.rawValue)_\($0.replacingOccurrences(of: ".", with: "_"))" } ?? function.rawValue) }
    }
}

public indirect enum QueryExpr: Equatable, Sendable {
    case and(QueryExpr, QueryExpr)
    case or(QueryExpr, QueryExpr)
    case not(QueryExpr)
    case compare(String, Comparison, QueryValue)
    case inList(String, [QueryValue])
    case between(String, QueryValue, QueryValue)
    case isNull(String)
    /// Any field contains the text (free words in shorthand).
    case text(String)

    public enum Comparison: String, Equatable, Sendable {
        case equal = "=", notEqual = "!=", greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<="
        /// Contains (case-insensitive), or for lists, has an element equal to the value.
        case contains = "~"
        case notContains = "!~"
        /// Regular expression.
        case matches = "=~"
    }
}

public enum QueryValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    /// A moment: a date literal, `now`, `today`, or a duration from now (`-24h`, `-7d`).
    case date(Date)
    /// The signed-in user, resolved by the host (`me`).
    case me
}

public struct QueryError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
