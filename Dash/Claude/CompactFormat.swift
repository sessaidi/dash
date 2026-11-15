import DashKit
import Foundation

/// How tool results reach Dashii and the agents: a token-lean form of JSON (inspired by TOON).
/// Field names come once per table instead of once per row, and there are no braces or quotes
/// around plain values. Whichever is shorter, this or minified JSON, is sent; `decode` reads both.
///
///     name: api
///     labels:
///       team: core
///     tags[2]: blue|green
///     pods[2]{name|restarts|status}:
///       api-1|0|Running
///       api-2|3|CrashLoopBackOff
///     mixed[2]:
///       - "text"
///       - id: 1
///
/// Keys holding null are left out, and an empty table cell is null.
enum CompactFormat {
    /// What Dashii is told once, in the system prompt.
    static let legend = """
        Tool results come in a compact form (or plain JSON when that's shorter): `k: v`; `k:` then lines indented \
        2 more is a nested object; `k[n]: a|b` is a list; `k[n]{f1|f2}:` is a table, then n rows `v1|v2` in header \
        order (empty cell = null); `k[n]:` then `- ` lines is a list of mixed items. Absent keys are null; quoted \
        values are JSON strings; values starting with [ or { are JSON.
        """

    static func encode(_ value: JSONValue) -> String {
        let json = value.jsonString()
        let compact: String
        switch value {
        case .object(let fields) where !fields.values.allSatisfy({ $0 == .null }):
            compact = entries(fields, indent: 0).joined(separator: "\n")
        case .array:
            compact = entry(nil, value, indent: 0).joined(separator: "\n")
        default:
            return json
        }
        return compact.utf8.count < json.utf8.count ? compact : json
    }

    // MARK: Encoding

    private static func entries(_ fields: [String: JSONValue], indent: Int) -> [String] {
        fields.filter { $0.value != .null }.sorted { $0.key < $1.key }.flatMap { entry($0.key, $0.value, indent: indent) }
    }

    private static func entry(_ key: String?, _ value: JSONValue, indent: Int) -> [String] {
        let head = String(repeating: " ", count: indent) + (key.map(keyToken) ?? "")
        switch value {
        case .object(let fields):
            let lines = entries(fields, indent: indent + 2)
            return lines.isEmpty ? ["\(head): {}"] : ["\(head):"] + lines
        case .array(let items):
            if items.isEmpty { return ["\(head)[0]:"] }
            if items.allSatisfy(\.isScalar) { return ["\(head)[\(items.count)]: " + items.map(cell).joined(separator: "|")] }
            let objects = items.compactMap(\.objectFields)
            let columns = Set(objects.flatMap { $0.filter { $0.value != .null }.keys }).sorted()
            if objects.count == items.count, items.count > 1, !columns.isEmpty {
                let pad = String(repeating: " ", count: indent + 2)
                return ["\(head)[\(items.count)]{\(columns.map(keyToken).joined(separator: "|"))}:"]
                    + objects.map { row in pad + columns.map { cell(row[$0] ?? .null) }.joined(separator: "|") }
            }
            return ["\(head)[\(items.count)]:"] + items.flatMap { item($0, indent: indent + 2) }
        default:
            return ["\(head): \(token(value))"]
        }
    }

    /// `- ` and the item, its first line on the dash and the rest indented under it.
    private static func item(_ value: JSONValue, indent: Int) -> [String] {
        let dash = String(repeating: " ", count: indent) + "- "
        let lines: [String]
        switch value {
        case .object(let fields): lines = entries(fields, indent: indent + 2)
        case .array: lines = entry(nil, value, indent: indent + 2)
        case .string: return [dash + value.jsonString()]
        default: return [dash + token(value)]
        }
        guard let first = lines.first else { return [dash + "{}"] }
        return [dash + first.dropFirst(indent + 2)] + lines.dropFirst()
    }

    private static func cell(_ value: JSONValue) -> String {
        switch value {
        case .null: ""
        case .array, .object: value.jsonString()
        default: token(value)
        }
    }

    private static func token(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
            return "\(number)"
        case .string(let text): return isPlain(text) ? text : value.jsonString()
        case .array, .object: return value.jsonString()
        }
    }

    private static let keyCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$/-@")

    private static func keyToken(_ key: String) -> String {
        guard let first = key.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first), first != "-",
              key.unicodeScalars.allSatisfy(keyCharacters.contains) else { return JSONValue.string(key).jsonString() }
        return key
    }

    /// A string that reads back as itself without quotes.
    private static func isPlain(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last, !first.isWhitespace, !last.isWhitespace,
              first != "-", last != ":", !["true", "false", "null"].contains(text), Double(text) == nil,
              !text.contains(": ") else { return false }
        return !text.contains { "\"[]{}|\n\r\t".contains($0) }
    }

    // MARK: Decoding

    /// Reads what `encode` wrote (or plain JSON).
    static func decode(_ text: String) throws -> JSONValue {
        if let json = try? JSONValue.parse(text) { return json }
        var reader = Reader(lines: text.components(separatedBy: "\n"))
        if text.hasPrefix("[") {
            reader.index = 1
            return try reader.value(after: text.components(separatedBy: "\n")[0], indent: 0)
        }
        return .object(try reader.object(indent: 0))
    }

    private struct Reader {
        let lines: [String]
        var index = 0

        func depth(of line: String) -> Int { line.prefix { $0 == " " }.count }

        mutating func object(indent: Int) throws -> [String: JSONValue] {
            var fields: [String: JSONValue] = [:]
            while index < lines.count, depth(of: lines[index]) == indent, !lines[index].dropFirst(indent).hasPrefix("- ") {
                let line = String(lines[index].dropFirst(indent))
                index += 1
                let (key, rest) = try Self.key(line)
                fields[key ?? ""] = try value(after: rest, indent: indent)
            }
            return fields
        }

        /// What follows a key: `: v`, `:` and a block, `[n]: a|b`, `[n]{…}:` and rows, `[n]:` and items.
        mutating func value(after rest: String, indent: Int) throws -> JSONValue {
            if rest == ":" { return .object(try object(indent: indent + 2)) }
            if rest.hasPrefix(": ") { return Self.scalar(String(rest.dropFirst(2))) }
            guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]"), let count = Int(rest[rest.index(after: rest.startIndex)..<close]) else {
                throw ToolError("Unreadable line: \(rest)")
            }
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix("{"), after.hasSuffix("}:") {
                let columns = try Self.split(String(after.dropFirst().dropLast(2))).map { try Self.key($0 + ":").key ?? "" }
                var rows: [JSONValue] = []
                for _ in 0..<count {
                    guard index < lines.count else { throw ToolError("Table ends early.") }
                    let cells = Self.split(String(lines[index].dropFirst(indent + 2)))
                    index += 1
                    var row: [String: JSONValue] = [:]
                    for (column, cell) in zip(columns, cells) where !cell.isEmpty { row[column] = Self.scalar(cell) }
                    rows.append(.object(row))
                }
                return .array(rows)
            }
            if after.hasPrefix(": ") { return .array(Self.split(String(after.dropFirst(2))).map { $0.isEmpty ? .null : Self.scalar($0) }) }
            guard after == ":" else { throw ToolError("Unreadable line: \(rest)") }
            var items: [JSONValue] = []
            for _ in 0..<count { items.append(try item(indent: indent + 2)) }
            return .array(items)
        }

        mutating func item(indent: Int) throws -> JSONValue {
            guard index < lines.count, lines[index].dropFirst(indent).hasPrefix("- ") else { throw ToolError("Expected a list item.") }
            let content = String(lines[index].dropFirst(indent + 2))
            index += 1
            if content.hasPrefix("[") { return try value(after: content, indent: indent + 2) }
            if let json = try? JSONValue.parse(content) { return json }
            let (key, rest) = try Self.key(content)
            var fields = [key ?? "": try value(after: rest, indent: indent + 2)]
            fields.merge(try object(indent: indent + 2)) { first, _ in first }
            return .object(fields)
        }

        /// The key of an entry line (quoted or bare) and the rest, from `:` or `[`.
        static func key(_ line: String) throws -> (key: String?, rest: String) {
            if line.hasPrefix("[") { return (nil, line) }
            if line.hasPrefix("\"") {
                var escaped = false
                for index in line.indices.dropFirst() {
                    if escaped { escaped = false; continue }
                    if line[index] == "\\" { escaped = true; continue }
                    if line[index] == "\"" {
                        let end = line.index(after: index)
                        return ((try? JSONValue.parse(String(line[..<end])))?.string, String(line[end...]))
                    }
                }
                throw ToolError("Unclosed key: \(line)")
            }
            guard let end = line.firstIndex(where: { $0 == ":" || $0 == "[" }) else { throw ToolError("No key: \(line)") }
            return (String(line[..<end]), String(line[end...]))
        }

        static func scalar(_ text: String) -> JSONValue {
            if let first = text.first, "\"[{".contains(first), let json = try? JSONValue.parse(text) { return json }
            switch text {
            case "true": return true
            case "false": return false
            case "null": return .null
            default: return Double(text).map(JSONValue.number) ?? .string(text)
            }
        }

        /// Splits on `|` outside quotes and JSON brackets.
        static func split(_ text: String) -> [String] {
            var parts: [String] = [], current = "", quoted = false, escaped = false, depth = 0
            for character in text {
                if quoted {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true
                } else if character == "[" || character == "{" { depth += 1
                } else if character == "]" || character == "}" { depth -= 1
                } else if character == "|", depth == 0 { parts.append(current); current = ""; continue }
                current.append(character)
            }
            parts.append(current)
            return parts
        }
    }
}

private extension JSONValue {
    var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }

    var objectFields: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
