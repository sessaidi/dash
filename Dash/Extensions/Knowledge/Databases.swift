import Foundation
import SQLite3

/// Database tables (`table:<schema>.<name>`, schema `public` when nothing says): the SQL files
/// creating and changing them (`file —migrates→ table`), the ORM models declaring them (`table
/// —defined_in→ file`: Prisma, Django, SQLAlchemy, TypeORM, GORM) and the code reading or writing
/// them in SQL string literals. Only identifiers are kept, never SQL text (scripts can hold
/// credentials). What a file says about columns is a fact (refs of kind `columns`) the link pass
/// replays in migration order into the table's node; reads and writes are refs by name, resolved
/// across repositories by `ServiceLinks`.
struct DatabaseExtractor: CodeExtractor {
    let name = "databases"
    var sharedKinds: [String] { ["table"] }

    /// Facts about a table's columns and indexes, replayed by `ExtractionLinks`.
    static let factKind = "columns"
    /// Reads and writes by table name, resolved by `ServiceLinks`.
    static let accessKinds: Set<String> = ["reads_table", "writes_table"]
    static let refKinds: Set<String> = accessKinds.union([factKind])

    func accepts(path: String, language: String) -> Bool {
        guard !SourceScan.isTest(path) else { return false }
        switch language {
        case "sql": return !Self.isDownMigration(path)
        case "prisma", "go", "typescript", "javascript", "python": return true
        default: return false
        }
    }

    /// golang-migrate `*.down.sql`, `*_down.sql` and Flyway undo migrations `U1__x.sql`.
    static func isDownMigration(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasSuffix(".down.sql") || name.hasSuffix("_down.sql") || name.range(of: #"^u\d+(?:[._]\d+)*__"#, options: .regularExpression) != nil
    }

    static func id(_ qualified: String) -> String { "table:" + qualified }

    func extract(_ file: ExtractionInput) -> Extraction {
        switch file.language {
        case "sql": return SQLScript.extract(file)
        case "prisma": return TableModels.prisma(file)
        default:
            var result = TableModels.extract(file)
            result.add(SQLInCode.extract(file))
            return result
        }
    }
}

// MARK: - SQL text

/// Splitting and reading SQL: statements outside quotes, dollar quotes and comments; identifiers.
enum SQLText {
    static let identifier = #"(?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[A-Za-z_][\w$]*)"#
    static let name = identifier + #"(?:\s*\.\s*"# + identifier + #"){0,2}"#

    /// The statements of a script with comments blanked, and the UTF-16 offset each starts at.
    static func statements(_ text: String) -> [(sql: String, offset: Int)] {
        let units = Array(text.utf16)
        var result: [(String, Int)] = []
        var current: [unichar] = []
        var start = -1
        var index = 0
        func append(_ unit: unichar, at position: Int) {
            if start < 0 && !SourceScan.isSpace(unit) { start = position }
            current.append(unit)
        }
        func flush() {
            let sql = String(utf16CodeUnits: current, count: current.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sql.isEmpty { result.append((sql, max(start, 0))) }
            current = []
            start = -1
        }
        while index < units.count {
            let unit = units[index]
            let next: unichar = index + 1 < units.count ? units[index + 1] : 0
            if unit == 45 && next == 45 {
                while index < units.count, units[index] != 10 { index += 1 }
                current.append(32)
            } else if unit == 47 && next == 42 {
                index += 2
                while index + 1 < units.count, !(units[index] == 42 && units[index + 1] == 47) { index += 1 }
                index += 2
                current.append(32)
            } else if unit == 39 || unit == 34 || unit == 96 {
                append(unit, at: index)
                index += 1
                while index < units.count {
                    current.append(units[index])
                    if units[index] == unit {
                        if index + 1 < units.count, units[index + 1] == unit { current.append(unit); index += 2; continue }
                        break
                    }
                    index += 1
                }
                index += 1
            } else if unit == 36, index == 0 || !SourceScan.isIdentifier(units[index - 1]), let tag = dollarTag(units, at: index) {
                // $$ … $$ or $body$ … $body$: function bodies, copied whole.
                var end = index + tag.count
                while end + tag.count <= units.count, Array(units[end..<end + tag.count]) != tag { end += 1 }
                end = min(units.count, end + tag.count)
                for position in index..<end { append(units[position], at: position) }
                index = end
            } else if unit == 59 {
                flush()
                index += 1
            } else {
                append(unit, at: index)
                index += 1
            }
        }
        flush()
        return result
    }

    private static func dollarTag(_ units: [unichar], at index: Int) -> [unichar]? {
        var end = index + 1
        while end < units.count, SourceScan.isIdentifier(units[end]), units[end] != 36 { end += 1 }
        guard end < units.count, units[end] == 36 else { return nil }
        if end > index + 1, units[index + 1] >= 48 && units[index + 1] <= 57 { return nil }
        return Array(units[index...end])
    }

    /// One identifier as the database knows it: quotes removed (case kept), unquoted lowercased.
    static func clean(_ part: String) -> String {
        let part = part.trimmingCharacters(in: .whitespaces)
        if let first = part.first, "\"`[".contains(first), part.count >= 2 { return String(part.dropFirst().dropLast()) }
        return part.lowercased()
    }

    /// A possibly qualified name split at dots outside quotes, cleaned; `db.schema.table` keeps
    /// the last two.
    static func parts(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in raw {
            if let open = quote {
                current.append(character)
                if character == (open == "[" ? "]" : open) { quote = nil }
            } else if "\"`[".contains(character) {
                quote = character
                current.append(character)
            } else if character == "." {
                parts.append(current)
                current = ""
            } else if !character.isWhitespace {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map(clean).filter { !$0.isEmpty }.suffix(2)
    }

    /// `schema.name` (the given schema when the name has none), or the bare name without one.
    static func qualified(_ raw: String, schema: String?) -> String? {
        let parts = parts(raw)
        guard let name = parts.last, !keywords.contains(name) else { return nil }
        if parts.count == 2 { return parts[0] + "." + name }
        return schema.map { $0 + "." + name } ?? name
    }

    static let keywords: Set<String> = ["select", "values", "lateral", "unnest", "dual", "where", "set", "only", "as", "on", "table", "if", "not", "exists"]

    /// The items of the parenthesised list starting at `open` in `text`, split at top-level commas.
    static func list(_ text: String, at open: String.Index) -> [String]? {
        let units = Array(text[open...].utf16)
        guard let call = SourceScan.arguments(units, at: 0, limit: 200_000) else { return nil }
        let string = String(text[open...]) as NSString
        return call.ranges.map { string.substring(with: $0) }
    }

    static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

/// The tables a statement reads (FROM, JOIN, USING) and writes (INSERT, UPDATE, DELETE, MERGE,
/// TRUNCATE, COPY … FROM), as written, minus CTE names and function calls.
enum SQLQuery {
    private static let name = "((?>" + SQLText.name + "))"
    private static let writePatterns = [
        #"(?i)\bINSERT\s+(?:IGNORE\s+)?INTO\s+"# + name,
        #"(?i)\bREPLACE\s+INTO\s+"# + name,
        #"(?i)\bUPDATE\s+(?:ONLY\s+)?"# + name + #"(?:\s+(?:AS\s+)?"# + SQLText.identifier + #")?\s+SET\b"#,
        #"(?i)\bDELETE\s+FROM\s+(?:ONLY\s+)?"# + name,
        #"(?i)\bMERGE\s+INTO\s+"# + name,
        #"(?i)\bTRUNCATE\s+(?:TABLE\s+)?(?:ONLY\s+)?"# + name,
        #"(?i)^\s*COPY\s+"# + name + #"\s*(?:\([^)]*\)\s*)?FROM\b"#,
    ]
    private static let read = #"(?i)(?<![@:$.\w])(FROM|JOIN|USING)\s+(?:ONLY\s+|LATERAL\s+)?"# + name + #"(?!\s*[(.])"#
    private static let more = #"(?i)\s*(?:(?:AS\s+)?(?!(?:WHERE|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|OUTER|ON|GROUP|ORDER|LIMIT|HAVING|UNION|WINDOW|FOR|RETURNING|SET|NATURAL|USING|OFFSET|FETCH|EXCEPT|INTERSECT|VALUES|SELECT)\b)"#
        + SQLText.identifier + #"\s*)?,\s*(?:LATERAL\s+)?"# + name + #"(?!\s*[(.])"#
    private static let cte = #"(?i)(?:\bWITH(?:\s+RECURSIVE)?|,)\s*("# + SQLText.identifier + #")\s*(?:\([^)]*\)\s*)?AS\s*(?:NOT\s+)?(?:MATERIALIZED\s+)?\("#
    private static let functions: Set<String> = ["extract", "substring", "trim", "position", "overlay"]

    static func tables(_ raw: String) -> (reads: [String], writes: [String]) {
        var reads: [String] = []
        var writes: [String] = []
        for statement in SQLText.statements(String(raw.prefix(20_000))) {
            let sql = statement.sql.replacingOccurrences(of: #"'(?:[^']|'')*'"#, with: "''", options: .regularExpression)
            let string = sql as NSString
            let whole = NSRange(location: 0, length: string.length)
            let ctes = Set(SourceScan.regex(cte).matches(in: sql, range: whole).map { SQLText.clean(string.substring(with: $0.range(at: 1))) })
            func add(_ range: NSRange, to list: inout [String]) {
                guard let table = SQLText.qualified(string.substring(with: range), schema: nil), !ctes.contains(table), !list.contains(table) else { return }
                list.append(table)
            }
            var targets = Set<Int>()
            for pattern in writePatterns {
                for match in SourceScan.regex(pattern).matches(in: sql, range: whole) {
                    targets.insert(match.range(at: 1).location)
                    add(match.range(at: 1), to: &writes)
                }
            }
            for match in SourceScan.regex(read).matches(in: sql, range: whole) where !targets.contains(match.range(at: 2).location) {
                let keyword = match.range(at: 1)
                if string.substring(with: keyword).uppercased() == "FROM" && insideFunction(string, before: keyword.location) { continue }
                if string.substring(to: keyword.location).range(of: #"(?i)\bDISTINCT\s*$"#, options: .regularExpression) != nil { continue }
                add(match.range(at: 2), to: &reads)
                var end = match.range.location + match.range.length
                while let next = SourceScan.regex(more).firstMatch(in: sql, options: .anchored, range: NSRange(location: end, length: string.length - end)) {
                    add(next.range(at: 1), to: &reads)
                    end = next.range.location + next.range.length
                }
            }
        }
        return (reads.filter { !writes.contains($0) }, writes)
    }

    /// `EXTRACT(year FROM x)`, `SUBSTRING(s FROM 2)`: a FROM inside such a call isn't a table's.
    private static func insideFunction(_ string: NSString, before offset: Int) -> Bool {
        var depth = 0
        var index = offset - 1
        while index >= 0 {
            let unit = string.character(at: index)
            if unit == 41 { depth += 1 } else if unit == 40 {
                if depth == 0 {
                    var start = index
                    while start > 0, SourceScan.isIdentifier(string.character(at: start - 1)) { start -= 1 }
                    return functions.contains(string.substring(with: NSRange(location: start, length: index - start)).lowercased())
                }
                depth -= 1
            }
            index -= 1
        }
        return false
    }
}

// MARK: - SQL files

/// Migrations and schema files: what each statement does to which table, in order.
enum SQLScript {
    private static let name = "(" + SQLText.name + ")"

    static func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        var schema: String?
        var line = 0
        func table(_ raw: String) -> String? { SQLText.qualified(raw, schema: schema ?? "public").map(DatabaseExtractor.id) }
        func migrates(_ id: String) {
            let edge = KnowledgeEdge(src: file.fileID, dst: id, kind: "migrates")
            if !result.edges.contains(edge) { result.edges.append(edge) }
        }
        func fact(_ src: String, _ names: [String]) {
            result.refs.append(KnowledgeRef(src: src, kind: DatabaseExtractor.factKind, names: names, line: line))
        }
        func access(_ src: String, _ sql: String) {
            let found = SQLQuery.tables(sql)
            for (kind, tables) in [("reads_table", found.reads), ("writes_table", found.writes)] {
                for table in tables {
                    let name = table.contains(".") ? table : schema.map { $0 + "." + table } ?? table
                    let ref = KnowledgeRef(src: src, kind: kind, names: [name], line: line)
                    if !result.refs.contains(ref) { result.refs.append(ref) }
                }
            }
        }
        func first(_ pattern: String, _ sql: String) -> [String]? { SourceScan.matches("(?is)^" + pattern, in: sql).first }

        for statement in SQLText.statements(file.text) {
            line = file.line(at: statement.offset)
            let sql = SQLText.collapsed(String(statement.sql.prefix(200_000)))
            if let match = first(#"SET\s+(?:LOCAL\s+|SESSION\s+)?search_path\s*(?:TO|=)\s*(.+)$"#, sql) ?? first(#"SET\s+SCHEMA\s+(\S+)"#, sql) ?? first(#"USE\s+("# + SQLText.identifier + ")$", sql) {
                let value = match[1].split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '")) }.first { !$0.contains("$") } ?? ""
                schema = value.isEmpty ? nil : SQLText.clean(value)
            } else if let match = first(#"CREATE\s+(?:OR\s+REPLACE\s+)?(?:(?:GLOBAL|LOCAL)\s+)?(TEMP\s+|TEMPORARY\s+|UNLOGGED\s+|FOREIGN\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"# + name + #"\s*(\()?"#, sql) {
                guard !match[1].uppercased().hasPrefix("TEMP"), let id = table(match[2]) else { continue }
                migrates(id)
                var columns: [String] = []
                if !match[3].isEmpty, let items = SQLText.list(sql, at: sql.index(sql.startIndex, offsetBy: match[0].count - 1)) {
                    columns = items.compactMap(column)
                }
                fact(id, ["create"] + columns)
            } else if let match = first(#"CREATE\s+(?:OR\s+REPLACE\s+)?(?:TEMP\w*\s+)?(?:RECURSIVE\s+)?(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?"# + name + #"\s*(\([^)]*\))?\s*AS\s+(.*)$"#, sql) {
                guard let id = table(match[1]) else { continue }
                migrates(id)
                let explicit = match[2].isEmpty ? nil : match[2].dropFirst().dropLast().split(separator: ",").map { SQLText.clean(String($0)) }
                fact(id, ["view"] + (explicit ?? selected(match[3])))
                access(id, match[3])
            } else if let match = first(#"ALTER\s+(?:FOREIGN\s+)?TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?"# + name + #"\s+(.*)$"#, sql) {
                guard let id = table(match[1]) else { continue }
                migrates(id)
                for action in SourceScan.splitTopLevel(match[2], separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if let rename = first(#"RENAME\s+TO\s+"# + name, action), let to = SQLText.parts(rename[1]).last {
                        let target = DatabaseExtractor.id(String(id.dropFirst(6).split(separator: ".").first ?? "public") + "." + to)
                        migrates(target)
                        fact(id, ["rename", target])
                    } else if let move = first(#"SET\s+SCHEMA\s+("# + SQLText.identifier + ")", action), let tableName = id.split(separator: ".", maxSplits: 1).last {
                        let target = DatabaseExtractor.id(SQLText.clean(move[1]) + "." + tableName)
                        migrates(target)
                        fact(id, ["rename", target])
                    } else if let rename = first(#"(?:RENAME\s+(?:COLUMN\s+)?("# + SQLText.identifier + #")\s+TO\s+|CHANGE\s+(?:COLUMN\s+)?("# + SQLText.identifier + #")\s+)("# + SQLText.identifier + ")", action),
                              !["constraint", "index", "key"].contains(SQLText.clean(rename[1] + rename[2])) {
                        fact(id, ["rename_column", SQLText.clean(rename[1] + rename[2]), SQLText.clean(rename[3])])
                    } else if let add = first(#"ADD\s+(?:COLUMN\s+)?(?:IF\s+NOT\s+EXISTS\s+)?("# + SQLText.identifier + ")", action),
                              !["constraint", "primary", "foreign", "unique", "check", "index", "key", "exclude"].contains(SQLText.clean(add[1])) {
                        fact(id, ["add", SQLText.clean(add[1])])
                    } else if let drop = first(#"DROP\s+(?:COLUMN\s+)?(?:IF\s+EXISTS\s+)?("# + SQLText.identifier + ")", action),
                              !["constraint", "primary", "foreign", "index", "key", "default", "not"].contains(SQLText.clean(drop[1])) {
                        fact(id, ["drop_column", SQLText.clean(drop[1])])
                    }
                }
            } else if let match = first(#"DROP\s+(?:MATERIALIZED\s+)?(?:FOREIGN\s+)?(?:TABLE|VIEW)\s+(?:IF\s+EXISTS\s+)?(.+?)(?:\s+(?:CASCADE|RESTRICT))?$"#, sql) {
                for raw in SourceScan.splitTopLevel(match[1], separator: ",") {
                    guard let id = table(raw) else { continue }
                    migrates(id)
                    fact(id, ["drop"])
                }
            } else if let match = first(#"DROP\s+INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+EXISTS\s+)?(.+?)(?:\s+(?:CASCADE|RESTRICT))?$"#, sql) {
                for raw in SourceScan.splitTopLevel(match[1], separator: ",") {
                    if let index = SQLText.parts(raw).last { fact(file.fileID, ["drop_index", index]) }
                }
            } else if let match = first(#"CREATE\s+(UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?(?:"# + name + #"\s+)?ON\s+(?:ONLY\s+)?"# + name + #"\s*(?:USING\s+\w+\s*)?\("#, sql) {
                guard let id = table(match[3]) else { continue }
                migrates(id)
                let columns = (SQLText.list(sql, at: sql.index(sql.startIndex, offsetBy: match[0].count - 1)) ?? []).map { item -> String in
                    item.range(of: "^" + SQLText.identifier + "$", options: .regularExpression) != nil ? SQLText.clean(item) : String(item.prefix(60))
                }
                fact(id, ["index", match[1].isEmpty ? "" : "unique", match[2].isEmpty ? "" : SQLText.parts(match[2]).last ?? "", columns.joined(separator: ", ")])
            } else if sql.range(of: #"(?i)^(?:INSERT|UPDATE|DELETE|MERGE|WITH|SELECT|COPY|TRUNCATE|REPLACE)\b"#, options: .regularExpression) != nil {
                access(file.fileID, sql)
            }
        }
        return result
    }

    /// The column a `CREATE TABLE` item declares (nil for constraints).
    private static func column(_ item: String) -> String? {
        guard let first = item.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init),
              !["constraint", "primary", "foreign", "unique", "check", "exclude", "like", "index", "key", "fulltext", "spatial", "period"].contains(first.lowercased()),
              first.range(of: "^" + SQLText.identifier + "$", options: .regularExpression) != nil else { return nil }
        return SQLText.clean(first)
    }

    /// The column names a view's `SELECT a, b AS c, t.d FROM …` gives (aliases, else last parts).
    private static func selected(_ query: String) -> [String] {
        guard let match = SourceScan.matches(#"(?is)^\s*SELECT\s+(?:DISTINCT\s+(?:ON\s*\([^)]*\)\s*)?)?(.*?)\s+FROM\s"#, in: query).first else { return [] }
        return SourceScan.splitTopLevel(match[1], separator: ",").compactMap { item in
            let item = item.trimmingCharacters(in: .whitespaces)
            if let alias = SourceScan.matches(#"(?i)\s(?:AS\s+)?("# + SQLText.identifier + ")$", in: item).first?[1], item.contains(" ") { return SQLText.clean(alias) }
            if item.range(of: "^" + SQLText.name + "$", options: .regularExpression) != nil, let last = SQLText.parts(item).last { return last }
            return nil
        }
    }
}

// MARK: - SQL in code

/// SQL in string literals of Go, TypeScript/JavaScript and Python: refs from the function holding
/// it, or from the functions using the constant it's assigned to.
enum SQLInCode {
    static func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        let start = SourceScan.regex(#"(?i)(?:"""|'''|["'`])\s*(?:SELECT|INSERT|UPDATE|DELETE|WITH|MERGE|REPLACE)\s"#)
        for match in file.matches(start) {
            let quote = file.units[match.range.location]
            let triple = quote != 96 && file.units[match.range.location + 1] == quote && file.units[match.range.location + 2] == quote
            let contentStart = match.range.location + (triple ? 3 : 1)
            guard let end = literalEnd(file.units, from: contentStart, quote: quote, triple: triple) else { continue }
            let body = file.string.substring(with: NSRange(location: contentStart, length: min(end - contentStart, 20_000)))
            guard looksLikeSQL(body) else { continue }
            let found = SQLQuery.tables(body)
            guard !found.reads.isEmpty || !found.writes.isEmpty else { continue }
            let line = file.line(at: match.range.location)
            for src in sources(file, at: match.range.location, line: line) {
                for (kind, tables) in [("reads_table", found.reads), ("writes_table", found.writes)] {
                    for table in tables {
                        let ref = KnowledgeRef(src: src, kind: kind, names: [table], line: line)
                        if !result.refs.contains(ref) { result.refs.append(ref) }
                    }
                }
            }
        }
        return result
    }

    private static func literalEnd(_ units: [unichar], from start: Int, quote: unichar, triple: Bool) -> Int? {
        var index = start
        while index < units.count {
            let unit = units[index]
            if unit == 92 && quote != 96 { index += 2; continue }
            if unit == 10 && quote != 96 && !triple { return nil }
            if unit == quote && (!triple || (index + 2 < units.count && units[index + 1] == quote && units[index + 2] == quote)) { return index }
            index += 1
        }
        return nil
    }

    /// Uppercase SQL, or lowercase with something only SQL has (English "Select a file from…" isn't).
    static func looksLikeSQL(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyword = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }
        if keyword == keyword.uppercased() { return true }
        return trimmed.range(of: #"(?i)\bwhere\b|\bjoin\b|\$\d|\*|\bgroup\s+by\b|\border\s+by\b|\blimit\b|\bvalues\b|\bset\b|\binto\b|\breturning\b|="#, options: .regularExpression) != nil
    }

    /// The function around the literal; for a constant outside any function, the functions of
    /// the file naming that constant; else the file.
    private static func sources(_ file: ExtractionInput, at offset: Int, line: Int) -> [String] {
        if let symbol = file.symbol(at: line) { return [symbol] }
        let before = file.lineText(before: offset)
        if let constant = SourceScan.matches(#"(\w+)(?:\s+string)?\s*(?::=|=|:)\s*$"#, in: before).first?[1] {
            let word = SourceScan.regex(#"\b"# + NSRegularExpression.escapedPattern(for: constant) + #"\b"#)
            let users = file.parsed.symbols.indices.filter { index in
                let symbol = file.parsed.symbols[index]
                guard ["function", "method"].contains(symbol.kind), symbol.line != line else { return false }
                let start = file.offset(ofLine: symbol.line)
                let end = file.offset(ofLine: max(symbol.endLine, symbol.line) + 1)
                return end > start && word.firstMatch(in: file.text, range: NSRange(location: start, length: end - start)) != nil
            }
            if !users.isEmpty { return users.map { file.symbolIDs[$0] } }
        }
        return [file.fileID]
    }
}

// MARK: - Models

/// ORM models: the table each declares and its columns, as a `model` fact.
enum TableModels {
    struct Model {
        var table: String
        var framework: String
        var type: String
        var columns: [String]
        var line: Int
    }

    static func extract(_ file: ExtractionInput) -> Extraction {
        var models: [Model] = []
        switch file.language {
        case "python":
            if file.text.contains("django") { models += django(file) }
            if file.text.contains("sqlalchemy") || file.text.contains("__tablename__") { models += sqlalchemy(file) }
        case "go":
            if file.text.contains("TableName()") { models += gorm(file) }
        default:
            if file.text.contains("typeorm") && file.text.contains("@Entity") { models += typeorm(file) }
        }
        return extraction(models, in: file)
    }

    static func extraction(_ models: [Model], in file: ExtractionInput) -> Extraction {
        var result = Extraction()
        for model in models {
            let id = DatabaseExtractor.id(model.table.contains(".") ? model.table : "public." + model.table)
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            result.refs.append(KnowledgeRef(src: id, kind: DatabaseExtractor.factKind, names: ["model", model.framework, model.type] + model.columns, line: model.line))
        }
        return result
    }

    /// `snake_case` as GORM and TypeORM name things: `UserID` → `user_id`, `HTTPCode` → `http_code`.
    static func snake(_ name: String) -> String {
        let characters = Array(name)
        var result = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase, index > 0 {
                let previous = characters[index - 1]
                let nextLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextLower) { result += "_" }
            }
            result += character.lowercased()
        }
        return result
    }

    /// A Python class body: the lines after its header up to the next unindented one.
    private static func pythonBody(_ file: ExtractionInput, after match: NSTextCheckingResult) -> String {
        let start = match.range.location + match.range.length
        let rest = NSRange(location: start, length: file.string.length - start)
        let end = SourceScan.regex(#"\n(?=[^\s#])"#).firstMatch(in: file.text, range: rest)?.range.location ?? file.string.length
        return file.string.substring(with: NSRange(location: start, length: end - start))
    }

    /// Prisma `model X { … }`: scalar and enum fields (`@map` renames), `@@map`, `@@schema`.
    static func prisma(_ file: ExtractionInput) -> Extraction {
        let scalars: Set<String> = ["String", "Boolean", "Int", "BigInt", "Float", "Decimal", "DateTime", "Json", "Bytes", "Unsupported"]
        let enums = Set(SourceScan.matches(#"(?m)^enum\s+(\w+)\s*\{"#, in: file.text).map { $0[1] })
        var models: [Model] = []
        for match in file.matches(SourceScan.regex(#"(?m)^model\s+(\w+)\s*\{"#)) {
            let open = match.range.location + match.range.length - 1
            guard let close = file.closing(at: open) else { continue }
            let type = file.text(match.range(at: 1))
            var table = type
            var schema = "public"
            var columns: [String] = []
            for raw in file.text(NSRange(location: open + 1, length: close - open - 1)).split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("@@") {
                    if let mapped = SourceScan.matches(#"^@@map\(\s*(?:name:\s*)?"([^"]+)""#, in: line).first?[1] { table = mapped }
                    if let named = SourceScan.matches(#"^@@schema\(\s*"([^"]+)""#, in: line).first?[1] { schema = named }
                    continue
                }
                guard let field = SourceScan.matches(#"^(\w+)\s+(\w+)(\[\])?\??(.*)$"#, in: line).first,
                      scalars.contains(field[2]) || enums.contains(field[2]), !field[4].contains("@relation") else { continue }
                columns.append(SourceScan.matches(#"@map\(\s*(?:name:\s*)?"([^"]+)""#, in: field[4]).first?[1] ?? field[1])
            }
            models.append(Model(table: schema + "." + table, framework: "prisma", type: type, columns: columns, line: file.line(at: match.range.location)))
        }
        return extraction(models, in: file)
    }

    /// Django `class X(models.Model)`: `<app>_<model>` unless `Meta.db_table`; `id` unless a
    /// field is the primary key; foreign keys as `<name>_id`.
    static func django(_ file: ExtractionInput) -> [Model] {
        var models: [Model] = []
        let folders = file.directory.split(separator: "/").map(String.init)
        let app = folders.last == "models" ? folders.dropLast().last ?? "" : folders.last ?? ""
        for match in file.matches(SourceScan.regex(#"(?m)^class\s+(\w+)\s*\(([^)]*\bmodels\.Model\b[^)]*)\)\s*:"#)) {
            let body = pythonBody(file, after: match)
            if body.range(of: #"(?m)^\s+(?:abstract|proxy)\s*=\s*True"#, options: .regularExpression) != nil { continue }
            let type = file.text(match.range(at: 1))
            let table = SourceScan.matches(#"(?m)^\s+db_table\s*=\s*["']([^"']+)["']"#, in: body).first?[1] ?? (app.isEmpty ? "" : app.lowercased() + "_") + type.lowercased()
            var columns: [String] = []
            for field in SourceScan.matches(#"(?m)^[ \t]+(\w+)\s*=\s*models\.(\w+)\(([^\n]*)"#, in: body) where field[2] != "ManyToManyField" && (field[2].hasSuffix("Field") || field[2] == "ForeignKey") {
                let column = SourceScan.matches(#"db_column\s*=\s*["'](\w+)["']"#, in: field[3]).first?[1]
                    ?? (["ForeignKey", "OneToOneField"].contains(field[2]) ? field[1] + "_id" : field[1])
                columns.append(column)
            }
            if body.range(of: #"primary_key\s*=\s*True"#, options: .regularExpression) == nil { columns.insert("id", at: 0) }
            models.append(Model(table: table, framework: "django", type: type, columns: columns, line: file.line(at: match.range.location)))
        }
        return models
    }

    /// SQLAlchemy declarative classes with `__tablename__` (schema from `__table_args__`) and
    /// Core `Table("name", metadata, Column("id", …), schema="x")`.
    static func sqlalchemy(_ file: ExtractionInput) -> [Model] {
        var models: [Model] = []
        for match in file.matches(SourceScan.regex(#"(?m)^class\s+(\w+)\s*\([^)]*\)\s*:"#)) {
            let body = pythonBody(file, after: match)
            guard let table = SourceScan.matches(#"(?m)^\s+__tablename__\s*=\s*["']([^"']+)["']"#, in: body).first?[1] else { continue }
            let schema = SourceScan.matches(#"["']schema["']\s*:\s*["'](\w+)["']"#, in: body).first?[1]
            let columns = SourceScan.matches(#"(?m)^[ \t]+(\w+)\s*(?::\s*Mapped\[[^\n=]*\]\s*)?=\s*(?:\w+\.)?(?:Column|mapped_column)\((\s*["'](\w+)["'])?"#, in: body).map { $0[3].isEmpty ? $0[1] : $0[3] }
            models.append(Model(table: schema.map { $0 + "." + table } ?? table, framework: "sqlalchemy", type: file.text(match.range(at: 1)), columns: columns, line: file.line(at: match.range.location)))
        }
        for call in file.messagingCalls(#"(?<![\w.])(?:sa\.|sqlalchemy\.)?Table\("#) {
            guard let table = call.arguments.first.flatMap({ SourceScan.literal($0) }), !table.isEmpty else { continue }
            let columns = call.arguments.compactMap { SourceScan.matches(#"^(?:\w+\.)?Column\(\s*["'](\w+)["']"#, in: $0).first?[1] }
            let schema = SourceScan.keyword("schema", in: call.arguments).flatMap { SourceScan.literal($0) }
            models.append(Model(table: schema.map { $0 + "." + table } ?? table, framework: "sqlalchemy", type: table, columns: columns, line: file.line(at: call.match.range.location)))
        }
        return models
    }

    /// TypeORM `@Entity('name')` / `@Entity({ name, schema })` classes (snake_case of the class
    /// otherwise) and their column decorators.
    static func typeorm(_ file: ExtractionInput) -> [Model] {
        var models: [Model] = []
        for call in file.messagingCalls(#"@Entity\("#) {
            let after = call.match.range.location + call.match.range.length
            guard let declaration = SourceScan.regex(#"\bclass\s+(\w+)[^{]*\{"#).firstMatch(in: file.text, range: NSRange(location: after, length: file.string.length - after)),
                  let close = file.closing(at: declaration.range.location + declaration.range.length - 1) else { continue }
            let type = file.text(declaration.range(at: 1))
            let options = call.arguments.first ?? ""
            let table = SourceScan.literal(options) ?? SourceScan.matches(#"\bname\s*:\s*['"]([^'"]+)['"]"#, in: options).first?[1] ?? snake(type)
            let schema = SourceScan.matches(#"\bschema\s*:\s*['"]([^'"]+)['"]"#, in: options).first?[1]
            let start = declaration.range.location + declaration.range.length
            let body = NSRange(location: start, length: close - start)
            var columns: [String] = []
            for column in file.matches(SourceScan.regex(#"@(?:Column|PrimaryGeneratedColumn|PrimaryColumn|CreateDateColumn|UpdateDateColumn|DeleteDateColumn|VersionColumn|JoinColumn)\("#))
            where NSLocationInRange(column.range.location, body) {
                guard let arguments = file.arguments(at: column.range.location + column.range.length - 1) else { continue }
                let text = arguments.ranges.map(file.text).joined(separator: ",")
                if let named = SourceScan.matches(#"\bname\s*:\s*['"](\w+)['"]"#, in: text).first?[1] { columns.append(named); continue }
                if file.text(column.range).hasPrefix("@JoinColumn") { continue }
                let rest = NSRange(location: arguments.end, length: min(400, close - arguments.end))
                if let property = SourceScan.regex(#"(?:(?:public|private|protected|readonly|declare)\s+)*([A-Za-z_]\w*)[?!]?\s*:"#).firstMatch(in: file.text, range: rest) {
                    columns.append(file.text(property.range(at: 1)))
                }
            }
            models.append(Model(table: schema.map { $0 + "." + table } ?? table, framework: "typeorm", type: type, columns: columns, line: file.line(at: call.match.range.location)))
        }
        return models
    }

    /// GORM models with a `TableName()` method: their struct's fields as snake_case columns
    /// (`gorm:"column:x"` renames, `gorm:"-"` skips; `gorm.Model` adds its four).
    static func gorm(_ file: ExtractionInput) -> [Model] {
        var models: [Model] = []
        let basic = #"^\*?(?:string|bool|u?int\d*|float\d+|byte|rune|\[\]byte|time\.Time|json\.RawMessage|sql\.Null\w+|uuid\.UUID|decimal\.Decimal|datatypes\.\w+|gorm\.DeletedAt|pq\.\w+Array|pgtype\.\w+)$"#
        for match in file.matches(SourceScan.regex(#"(?m)^func\s+\(\s*(?:\w+\s+)?\*?(\w+)\s*\)\s+TableName\(\)\s+string\s*\{\s*return\s+"([^"]+)""#)) {
            let type = file.text(match.range(at: 1))
            var columns: [String] = []
            if let declaration = SourceScan.regex(#"(?m)^type\s+"# + type + #"\s+struct\s*\{"#).firstMatch(in: file.text, range: NSRange(location: 0, length: file.string.length)),
               let close = file.closing(at: declaration.range.location + declaration.range.length - 1) {
                let start = declaration.range.location + declaration.range.length
                for raw in file.text(NSRange(location: start, length: close - start)).split(separator: "\n") {
                    let line = SourceScan.withoutLineComment(String(raw)).trimmingCharacters(in: .whitespaces)
                    guard let field = SourceScan.matches(#"^([A-Z]\w*|\*?[\w.]+)(?:\s+([\w.*\[\]]+))?(?:\s+`([^`]*)`)?$"#, in: line).first else { continue }
                    let tag = SourceScan.matches(#"gorm:"([^"]*)""#, in: field[3]).first?[1] ?? ""
                    if tag == "-" || tag.hasPrefix("-:") { continue }
                    if field[2].isEmpty {
                        if field[1].hasSuffix("gorm.Model") { columns += ["id", "created_at", "updated_at", "deleted_at"] }
                        continue
                    }
                    if let named = SourceScan.matches(#"(?:^|;)column:(\w+)"#, in: tag).first?[1] { columns.append(named); continue }
                    guard field[2].range(of: basic, options: .regularExpression) != nil || tag.contains("type:") else { continue }
                    columns.append(snake(field[1]))
                }
            }
            models.append(Model(table: file.text(match.range(at: 2)), framework: "gorm", type: type, columns: columns, line: file.line(at: match.range.location)))
        }
        return models
    }
}

// MARK: - Replay and resolution

/// What the facts of a repository say about each table, replayed in migration order.
enum TableHistory {
    struct Table {
        var columns: [String] = []
        var view = false
        var created: (path: String, line: Int)?
        var dropped: String?
        var renamed: (to: String, path: String)?
        var indexes: [(name: String, unique: Bool, columns: String)] = []
        var migrations: [String] = []
        var model: (framework: String, type: String, path: String, line: Int, columns: [String])?
    }

    /// Facts from SQL files in path order (numbers compared as numbers, so `V10__` follows
    /// `V9__`), then statement order; models apart.
    static func replay(_ facts: [(path: String, ref: KnowledgeRef)]) -> [String: Table] {
        var tables: [String: Table] = [:]
        let ordered = facts.enumerated().sorted { a, b in
            let order = a.element.path.compare(b.element.path, options: .numeric)
            if order != .orderedSame { return order == .orderedAscending }
            return a.element.ref.line != b.element.ref.line ? a.element.ref.line < b.element.ref.line : a.offset < b.offset
        }.map(\.element)
        for (path, ref) in ordered {
            guard let operation = ref.names.first else { continue }
            let values = Array(ref.names.dropFirst())
            if operation == "drop_index" {
                for id in tables.keys { tables[id]?.indexes.removeAll { $0.name == values.first } }
                continue
            }
            var table = tables[ref.src] ?? Table()
            if operation != "model", !table.migrations.contains(path) { table.migrations.append(path) }
            switch operation {
            case "create", "view":
                table.columns = values
                table.view = operation == "view"
                table.dropped = nil
                table.renamed = nil
                table.created = (path, ref.line)
            case "add":
                table.columns += values.filter { !table.columns.contains($0) }
            case "drop_column":
                table.columns.removeAll { values.contains($0) }
            case "rename_column" where values.count == 2:
                table.columns = table.columns.map { $0 == values[0] ? values[1] : $0 }
            case "rename" where values.count == 1:
                var moved = table
                moved.renamed = nil
                moved.migrations = (tables[values[0]]?.migrations ?? []) + [path]
                tables[values[0]] = moved
                table.renamed = (values[0], path)
                table.columns = []
                table.indexes = []
            case "drop":
                table.dropped = path
            case "index" where values.count == 3:
                table.indexes.removeAll { !values[1].isEmpty && $0.name == values[1] }
                table.indexes.append((values[1], values[0] == "unique", values[2]))
            case "model" where values.count >= 2:
                table.model = (values[0], values[1], path, ref.line, Array(values.dropFirst(2)))
            default:
                break
            }
            tables[ref.src] = table
        }
        return tables
    }

    static func nodes(_ tables: [String: Table]) -> [KnowledgeNode] {
        tables.sorted { $0.key < $1.key }.map { id, table in
            let qualified = String(id.dropFirst(6))
            let name = String(qualified.split(separator: ".", maxSplits: 1).last ?? Substring(qualified))
            var signature = (table.view ? "view " : "table ") + qualified
            let columns = table.created == nil && table.columns.isEmpty ? table.model?.columns ?? [] : table.columns
            if let renamed = table.renamed {
                signature += ", renamed to \(renamed.to.dropFirst(6)) in \(renamed.path)"
            } else if let dropped = table.dropped {
                signature += ", dropped in \(dropped)"
            } else if !columns.isEmpty {
                signature += " (" + columns.prefix(40).joined(separator: ", ") + (columns.count > 40 ? ", … \(columns.count - 40) more" : "") + ")"
            }
            var summary: [String] = []
            if let created = table.created {
                let more = table.migrations.count - 1
                summary.append("Created in \(created.path)" + (more > 0 ? ", changed by \(more) more migration\(more == 1 ? "" : "s")" : "") + ".")
            } else if !table.migrations.isEmpty {
                summary.append("Migrated in " + table.migrations.prefix(3).joined(separator: ", ") + (table.migrations.count > 3 ? " and \(table.migrations.count - 3) more" : "") + ".")
            }
            if let model = table.model { summary.append("\(model.framework) model \(model.type) in \(model.path).") }
            if !table.indexes.isEmpty, table.renamed == nil, table.dropped == nil {
                summary.append("Indexes: " + table.indexes.prefix(10).map { index in
                    [index.name, "(\(index.columns)\(index.unique ? ", unique" : ""))"].filter { !$0.isEmpty }.joined(separator: " ")
                }.joined(separator: "; ") + ".")
            }
            let origin = table.created.map { ($0.path, $0.line) } ?? table.model.map { ($0.path, $0.line) } ?? (table.migrations.first ?? "", 0)
            return KnowledgeNode(id: id, kind: "table", name: name, qualified: qualified, path: origin.0, line: origin.1,
                                 language: table.migrations.isEmpty ? table.model?.framework ?? "sql" : "sql",
                                 signature: signature, summary: summary.joined(separator: " "), source: "code")
        }
    }

    /// A table that still exists (not dropped or renamed away).
    static func isLive(_ signature: String) -> Bool {
        !signature.contains(", dropped in ") && !signature.contains(", renamed to ")
    }

    /// Reads and writes by name to tables: a qualified name is that table; a bare one the live
    /// table of that name the same repository migrates or models (0.9), else the only one in any
    /// repository (0.6), split between two or three (0.3), else `public.<name>` (0.6). Tables no
    /// file defines get a placeholder node.
    static func resolve(_ accesses: [(repo: String, ref: KnowledgeRef)], defined: [(id: String, name: String, repo: String, live: Bool)],
                        source: String) -> (edges: [KnowledgeEdge], placeholders: [KnowledgeNode]) {
        let live = defined.filter(\.live)
        let byName = Dictionary(grouping: live, by: \.name)
        let known = Set(defined.map(\.id))
        var edges: [KnowledgeEdge] = []
        var placeholders: [String: KnowledgeNode] = [:]
        for (repo, ref) in accesses {
            guard let name = ref.names.first, !name.isEmpty else { continue }
            var targets: [(String, Double)]
            if name.contains(".") {
                targets = [(DatabaseExtractor.id(name), 1)]
            } else {
                let candidates = byName[name] ?? []
                let local = Array(Set(candidates.filter { $0.repo == repo }.map(\.id))).sorted()
                let anywhere = Array(Set(candidates.map(\.id))).sorted()
                targets = local.count == 1 ? [(local[0], 0.9)]
                    : (2...3).contains(local.count) ? local.map { ($0, 0.3) }
                    : anywhere.count == 1 ? [(anywhere[0], 0.6)]
                    : (2...3).contains(anywhere.count) ? anywhere.map { ($0, 0.3) }
                    : [(DatabaseExtractor.id("public." + name), 0.6)]
            }
            for (id, weight) in targets {
                edges.append(KnowledgeEdge(src: ref.src, dst: id, kind: ref.kind, weight: weight, source: source))
                if !known.contains(id), placeholders[id] == nil {
                    let qualified = String(id.dropFirst(6))
                    placeholders[id] = KnowledgeNode(id: id, kind: "table", name: String(qualified.split(separator: ".", maxSplits: 1).last ?? ""),
                                                     qualified: qualified, signature: "table " + qualified, source: "code")
                }
            }
        }
        return (edges, Array(placeholders.values))
    }
}

extension KnowledgeStore {
    /// Reads and writes of tables by name, with the repository of the code doing them.
    func tableAccesses() throws -> [(repo: String, ref: KnowledgeRef)] {
        let statement = try prepare("SELECT repo, src, kind, names, line FROM refs WHERE kind IN ('reads_table', 'writes_table')")
        defer { sqlite3_finalize(statement) }
        var result: [(String, KnowledgeRef)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), KnowledgeRef(src: text(statement, 1), kind: text(statement, 2), names: text(statement, 3).components(separatedBy: "\n"),
                                                            line: Int(sqlite3_column_int64(statement, 4)))))
        }
        return result
    }

    /// Tables some file migrates or models, with that file's repository.
    func definedTables() throws -> [(id: String, name: String, repo: String, live: Bool)] {
        let statement = try prepare("""
            SELECT n.id, n.name, n.signature, f.repo FROM edges e JOIN nodes n ON n.id = e.dst JOIN nodes f ON f.id = e.src
            WHERE e.kind = 'migrates' AND e.dst >= 'table:' AND e.dst < 'table;'
            UNION
            SELECT n.id, n.name, n.signature, f.repo FROM edges e JOIN nodes n ON n.id = e.src JOIN nodes f ON f.id = e.dst
            WHERE e.kind = 'defined_in' AND e.src >= 'table:' AND e.src < 'table;'
            """)
        defer { sqlite3_finalize(statement) }
        var result: [(String, String, String, Bool)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), text(statement, 1), text(statement, 3), TableHistory.isLive(text(statement, 2))))
        }
        return result
    }

    /// Adds the nodes not already there (placeholders never overwrite a real node).
    func insertMissing(_ nodes: [KnowledgeNode]) throws {
        try upsert(try nodes.filter { try node($0.id) == nil })
    }
}
