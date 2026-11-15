import Foundation

extension DashQuery {
    /// Parses DashQL. Throws a `QueryError` saying what was expected and where.
    public static func parse(_ text: String, now: Date = .now) throws -> DashQuery {
        let segments = splitTopLevel(text, on: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let head = segments.first, !head.isEmpty else { throw QueryError("Empty query. Start with a dataset, e.g. `from pods`.") }
        var (source, stages) = try parseHead(head, now: now)
        for segment in segments.dropFirst() where !segment.isEmpty {
            stages.append(try parseStage(segment, now: now))
        }
        source.dataset = source.dataset.lowercased()
        return DashQuery(source: source, stages: stages)
    }

    // MARK: Head: `from name ["arg"] [where …]` or `name shorthand…`

    private static func parseHead(_ text: String, now: Date) throws -> (Source, [Stage]) {
        var lexer = QueryLexer(text, now: now)
        var stages: [Stage] = []
        let source: Source
        if lexer.peekKeyword("from") {
            lexer.next()
            source = try parseSource(&lexer)
            if lexer.peekKeyword("where") {
                lexer.next()
                stages.append(.filter(try parseExpression(&lexer)))
                try lexer.expectEnd()
            } else if !lexer.atEnd {
                stages += try shorthand(lexer.rest, now: now)
            }
        } else {
            guard case .word(let name)? = lexer.next() else { throw QueryError("Start with a dataset, e.g. `from pods` or `pods ns:prod`.") }
            source = Source(dataset: name, argument: nil)
            if !lexer.atEnd { stages += try shorthand(lexer.rest, now: now) }
        }
        return (source, stages)
    }

    private static func parseSource(_ lexer: inout QueryLexer) throws -> Source {
        guard case .word(let name)? = lexer.next() else { throw QueryError("Expected a dataset name after `from`.") }
        var argument: String?
        if case .string(let value)? = lexer.peek { lexer.next(); argument = value }
        return Source(dataset: name.lowercased(), argument: argument)
    }

    // MARK: Stages

    private static func parseStage(_ text: String, now: Date) throws -> Stage {
        var lexer = QueryLexer(text, now: now)
        guard case .word(let keyword)? = lexer.next() else { throw QueryError("Expected a stage (where, sort, take, select, count by, summarize, distinct, join, search) in `\(text)`.") }
        switch keyword.lowercased() {
        case "where", "filter":
            let expression = try parseExpression(&lexer)
            try lexer.expectEnd()
            return .filter(expression)
        case "search":
            guard case .string(let value)? = lexer.next() ?? .string(lexer.rest) else { throw QueryError("search takes text in quotes.") }
            return .search(value)
        case "sort", "order":
            if lexer.peekKeyword("by") { lexer.next() }
            var keys: [SortKey] = []
            repeat {
                guard case .word(var field)? = lexer.next() else { throw QueryError("sort takes fields, e.g. `sort -restarts, name`.") }
                var descending = false
                if field.hasPrefix("-") { descending = true; field.removeFirst() }
                if lexer.peekKeyword("desc") { lexer.next(); descending = true } else if lexer.peekKeyword("asc") { lexer.next() }
                keys.append(SortKey(field: field, descending: descending))
            } while lexer.skip(.comma)
            try lexer.expectEnd()
            return .sort(keys)
        case "take", "limit", "head":
            guard case .number(let count)? = lexer.next(), count >= 0, let whole = Int(exactly: min(count.rounded(.down), 1_000_000)) else {
                throw QueryError("take takes a number, e.g. `take 10`.")
            }
            try lexer.expectEnd()
            return .take(whole)
        case "select", "project", "fields":
            var projections: [Projection] = []
            repeat {
                guard case .word(let field)? = lexer.next() else { throw QueryError("select takes fields, e.g. `select name, restarts`.") }
                var alias: String?
                if lexer.peekKeyword("as") { lexer.next(); if case .word(let name)? = lexer.next() { alias = name } }
                projections.append(Projection(field: field, alias: alias))
            } while lexer.skip(.comma)
            try lexer.expectEnd()
            return .select(projections)
        case "distinct", "dedup":
            let fields = try fieldList(&lexer)
            return .distinct(fields)
        case "count":
            var by: [String] = []
            if lexer.peekKeyword("by") { lexer.next(); by = try fieldList(&lexer) }
            try lexer.expectEnd()
            return .summarize([Aggregate(function: .count, field: nil, alias: "count")], by: by)
        case "summarize", "stats", "aggregate":
            var aggregates: [Aggregate] = []
            repeat {
                guard case .word(let name)? = lexer.next(), let function = Aggregate.Function(rawValue: name.lowercased()) else {
                    throw QueryError("summarize takes count(), sum(x), avg(x), min(x), max(x) or distinct(x).")
                }
                try lexer.expect(.open)
                var field: String?
                if case .word(let inner)? = lexer.peek { lexer.next(); field = inner }
                try lexer.expect(.close)
                var alias: String?
                if lexer.peekKeyword("as") { lexer.next(); if case .word(let value)? = lexer.next() { alias = value } }
                aggregates.append(Aggregate(function: function, field: field, alias: alias))
            } while lexer.skip(.comma)
            var by: [String] = []
            if lexer.peekKeyword("by") { lexer.next(); by = try fieldList(&lexer) }
            try lexer.expectEnd()
            return .summarize(aggregates, by: by)
        case "join", "lookup":
            let source = try parseSource(&lexer)
            guard lexer.peekKeyword("on") else { throw QueryError("join needs `on`, e.g. `join prs on key = ticket`.") }
            lexer.next()
            guard case .word(let left)? = lexer.next() else { throw QueryError("join: expected `on left = right`.") }
            guard case .op("=")? = lexer.next() else { throw QueryError("join: expected `=` between the two fields.") }
            guard case .word(let right)? = lexer.next() else { throw QueryError("join: expected the other dataset's field.") }
            var alias = source.dataset
            if lexer.peekKeyword("as") { lexer.next(); if case .word(let name)? = lexer.next() { alias = name } }
            try lexer.expectEnd()
            return .join(source, left: left, right: right, alias: alias)
        default:
            throw QueryError("Unknown stage `\(keyword)`. Stages: where, search, sort, take, select, distinct, count by, summarize, join.")
        }
    }

    private static func fieldList(_ lexer: inout QueryLexer) throws -> [String] {
        var fields: [String] = []
        repeat {
            guard case .word(let field)? = lexer.next() else { throw QueryError("Expected a field name.") }
            fields.append(field)
        } while lexer.skip(.comma)
        try lexer.expectEnd()
        return fields
    }

    // MARK: Expressions: or > and > not > comparison

    static func parseExpression(_ lexer: inout QueryLexer) throws -> QueryExpr {
        var left = try parseAnd(&lexer)
        while lexer.peekKeyword("or") {
            lexer.next()
            left = .or(left, try parseAnd(&lexer))
        }
        return left
    }

    private static func parseAnd(_ lexer: inout QueryLexer) throws -> QueryExpr {
        var left = try parseNot(&lexer)
        while lexer.peekKeyword("and") {
            lexer.next()
            left = .and(left, try parseNot(&lexer))
        }
        return left
    }

    private static func parseNot(_ lexer: inout QueryLexer) throws -> QueryExpr {
        if lexer.peekKeyword("not") { lexer.next(); return .not(try parseNot(&lexer)) }
        if lexer.skip(.open) {
            let inner = try parseExpression(&lexer)
            try lexer.expect(.close)
            return inner
        }
        return try parseComparison(&lexer)
    }

    private static func parseComparison(_ lexer: inout QueryLexer) throws -> QueryExpr {
        guard let token = lexer.next() else { throw QueryError("Expected a condition, e.g. `restarts > 3`.") }
        let field: String
        switch token {
        case .word(let name): field = name
        case .string(let text): return .text(text)
        default: throw QueryError("Expected a field name, got `\(token)`.")
        }
        if lexer.peekKeyword("in") {
            lexer.next()
            try lexer.expect(.open)
            var values: [QueryValue] = []
            repeat { values.append(try parseValue(&lexer)) } while lexer.skip(.comma)
            try lexer.expect(.close)
            return .inList(field, values)
        }
        if lexer.peekKeyword("not"), lexer.peekKeyword("in", offset: 1) {
            lexer.next(); lexer.next()
            try lexer.expect(.open)
            var values: [QueryValue] = []
            repeat { values.append(try parseValue(&lexer)) } while lexer.skip(.comma)
            try lexer.expect(.close)
            return .not(.inList(field, values))
        }
        if lexer.peekKeyword("between") {
            lexer.next()
            let low = try parseValue(&lexer)
            guard lexer.peekKeyword("and") else { throw QueryError("between needs `and`, e.g. `restarts between 1 and 5`.") }
            lexer.next()
            return .between(field, low, try parseValue(&lexer))
        }
        if lexer.peekKeyword("is") {
            lexer.next()
            let negated = lexer.peekKeyword("not")
            if negated { lexer.next() }
            guard lexer.peekKeyword("null") else { throw QueryError("Expected `is null` or `is not null`.") }
            lexer.next()
            return negated ? .not(.isNull(field)) : .isNull(field)
        }
        guard case .op(let symbol)? = lexer.next(), let comparison = QueryExpr.Comparison(rawValue: symbol) else {
            throw QueryError("Expected an operator after `\(field)`: = != > >= < <= ~ !~ =~ in between is.")
        }
        return .compare(field, comparison, try parseValue(&lexer))
    }

    static func parseValue(_ lexer: inout QueryLexer) throws -> QueryValue {
        guard let token = lexer.next() else { throw QueryError("Expected a value.") }
        switch token {
        case .string(let text): return .string(text)
        case .number(let number): return .number(number)
        case .date(let date): return .date(date)
        case .word(let word):
            switch word.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "me": return .me
            case "now": return .date(lexer.now)
            case "today": return .date(Calendar.current.startOfDay(for: lexer.now))
            case "yesterday": return .date(Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: lexer.now)) ?? lexer.now)
            default: return .string(word)
            }
        default: throw QueryError("Expected a value, got `\(token)`.")
        }
    }

    // MARK: Shorthand: `ns:prod -status:Running restarts>3 words "quoted words"`

    static func shorthand(_ text: String, now: Date) throws -> [Stage] {
        var conditions: [QueryExpr] = []
        for term in splitTerms(text) {
            var term = term
            let negated = term.hasPrefix("-") && term.count > 1 && !term.dropFirst().first!.isNumber
            if negated { term.removeFirst() }
            var expression: QueryExpr
            if term.wholeMatch(of: /[<>=!~:]+/) != nil || term.last.map({ "<>=!~:".contains($0) }) == true {
                throw QueryError("Incomplete condition `\(term)`: give a value, e.g. `restarts>3` or `ns:prod`.")
            }
            if let match = term.firstMatch(of: /^([A-Za-z_][\w.]*)(>=|<=|!=|>|<|=|:)(.+)$/) {
                let field = String(match.output.1), op = String(match.output.2)
                let raw = unquote(String(match.output.3))
                let values = splitTopLevel(raw, on: ",").map { literal($0.trimmingCharacters(in: .whitespaces), now: now) }
                if op == ":" {
                    // `status:crash,error`: contains any of them, like a single value does.
                    expression = values.dropFirst().reduce(.compare(field, .contains, values[0])) { .or($0, .compare(field, .contains, $1)) }
                } else {
                    expression = .compare(field, QueryExpr.Comparison(rawValue: op) ?? .equal, values[0])
                }
            } else {
                expression = .text(unquote(term))
            }
            conditions.append(negated ? .not(expression) : expression)
        }
        guard let first = conditions.first else { return [] }
        return [.filter(conditions.dropFirst().reduce(first) { .and($0, $1) })]
    }

    /// A shorthand value: a number, a date or duration, `me`, else text.
    static func literal(_ text: String, now: Date) -> QueryValue {
        var lexer = QueryLexer(text, now: now)
        if let value = try? parseValue(&lexer), lexer.atEnd { return value }
        return .string(text)
    }

    // MARK: Text helpers

    /// Splits on `separator` outside quotes and parentheses.
    static func splitTopLevel(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = [], current = "", quote: Character?, depth = 0
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character; current.append(character)
            } else if character == "(" { depth += 1; current.append(character) }
            else if character == ")" { depth -= 1; current.append(character) }
            else if character == separator, depth == 0 { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        return parts
    }

    /// Whitespace-separated terms, keeping quoted parts together (`name:"api gateway"`).
    static func splitTerms(_ text: String) -> [String] {
        var terms: [String] = [], current = "", quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character; current.append(character)
            } else if character.isWhitespace {
                if !current.isEmpty { terms.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { terms.append(current) }
        return terms
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        return String(text.dropFirst().dropLast())
    }
}

// MARK: - Lexer

enum QueryToken: Equatable, CustomStringConvertible {
    case word(String), string(String), number(Double), date(Date), op(String), open, close, comma

    var description: String {
        switch self {
        case .word(let word): word
        case .string(let text): "\"\(text)\""
        case .number(let number): String(number)
        case .date(let date): date.formatted(.iso8601)
        case .op(let symbol): symbol
        case .open: "("
        case .close: ")"
        case .comma: ","
        }
    }
}

struct QueryLexer {
    private var tokens: [QueryToken] = []
    private var index = 0
    /// The text not yet tokenised as structure, for shorthand after a source.
    private(set) var rest = ""
    private var restOffsets: [String.Index] = []
    private let text: String
    let now: Date

    init(_ text: String, now: Date) {
        self.text = text
        self.now = now
        tokenize()
    }

    var peek: QueryToken? { index < tokens.count ? tokens[index] : nil }
    var atEnd: Bool { index >= tokens.count }

    @discardableResult
    mutating func next() -> QueryToken? {
        guard index < tokens.count else { return nil }
        defer {
            index += 1
            rest = index < restOffsets.count ? String(text[restOffsets[index]...]) : ""
        }
        return tokens[index]
    }

    func peekKeyword(_ keyword: String, offset: Int = 0) -> Bool {
        guard index + offset < tokens.count, case .word(let word) = tokens[index + offset] else { return false }
        return word.lowercased() == keyword
    }

    mutating func skip(_ token: QueryToken) -> Bool {
        guard peek == token else { return false }
        next()
        return true
    }

    mutating func expect(_ token: QueryToken) throws {
        guard skip(token) else { throw QueryError("Expected `\(token)`\(peek.map { ", got `\($0)`" } ?? " at the end").") }
    }

    func expectEnd() throws {
        if let peek { throw QueryError("Unexpected `\(peek)`. Separate stages with `|`.") }
    }

    /// `2026-10-12` as the start of that day in the user's time zone.
    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private mutating func tokenize() {
        var position = text.startIndex
        let durations: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86_400, "w": 604_800]
        func add(_ token: QueryToken, from start: String.Index) {
            tokens.append(token)
            restOffsets.append(start)
        }
        while position < text.endIndex {
            let character = text[position]
            if character.isWhitespace { position = text.index(after: position); continue }
            let start = position
            let remaining = text[position...]
            if character == "\"" || character == "'" {
                var end = text.index(after: position)
                var value = ""
                while end < text.endIndex, text[end] != character {
                    if text[end] == "\\", text.index(after: end) < text.endIndex { end = text.index(after: end) }
                    value.append(text[end])
                    end = text.index(after: end)
                }
                position = end < text.endIndex ? text.index(after: end) : end
                add(.string(value), from: start)
            } else if character == "(" { add(.open, from: start); position = text.index(after: position) }
            else if character == ")" { add(.close, from: start); position = text.index(after: position) }
            else if character == "," { add(.comma, from: start); position = text.index(after: position) }
            else if let match = remaining.prefixMatch(of: /\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)?/) {
                let literal = String(match.output)
                // Without a time zone, a typed date and time is the user's local time.
                let date = DashDate.parse(literal)
                add(date.map(QueryToken.date) ?? .word(literal), from: start)
                position = match.range.upperBound
            } else if let match = remaining.prefixMatch(of: /([+-]?)(\d+(?:\.\d+)?)([smhdw])(?![\w])/) {
                let amount = (Double(match.output.2) ?? 0) * (durations[Character(String(match.output.3))] ?? 1)
                add(.date(now.addingTimeInterval(match.output.1 == "+" ? amount : -amount)), from: start)
                position = match.range.upperBound
            } else if let match = remaining.prefixMatch(of: /-?\d+(?:\.\d+)?(?![\w.-])/) {
                add(.number(Double(match.output) ?? 0), from: start)
                position = match.range.upperBound
            } else if let match = remaining.prefixMatch(of: /!=|>=|<=|=~|!~|[=<>~]/) {
                add(.op(String(match.output)), from: start)
                position = match.range.upperBound
            } else if let match = remaining.prefixMatch(of: /-?[A-Za-z_@][\w.\-\/@:]*/) {
                add(.word(String(match.output)), from: start)
                position = match.range.upperBound
            } else {
                add(.word(String(character)), from: start)
                position = text.index(after: position)
            }
        }
        restOffsets.append(text.endIndex)
        rest = text
    }
}

