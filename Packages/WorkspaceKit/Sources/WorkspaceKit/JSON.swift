import Foundation

/// Arbitrary JSON as exchanged with the Claude Code CLI.
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSON {
    public subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var double: Double? { if case .number(let value) = self { return value }; return nil }
    public var int: Int? { if case .number(let value) = self { return Int(exactly: value) }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var array: [JSON]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: JSON]? { if case .object(let value) = self { return value }; return nil }

    public static func parse(_ text: String) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
    }

    /// Go's `json.MarshalIndent(v, "", "  ")` of a decoded map: sorted keys, two-space indent,
    /// `<`, `>` and `&` escaped as \u003c, \u003e and \u0026 (what up-toolbox writes).
    public var pretty: String { goIndented(level: 0) }

    private func goIndented(level: Int) -> String {
        let pad = String(repeating: "  ", count: level + 1)
        let close = String(repeating: "  ", count: level)
        switch self {
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            let body = fields.keys.sorted().map { "\(pad)\(Self.goQuote($0)): \(fields[$0]!.goIndented(level: level + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(close)}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { pad + $0.goIndented(level: level + 1) }.joined(separator: ",\n") + "\n\(close)]"
        case .string(let text):
            return Self.goQuote(text)
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e21 ? String(Int64(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func goQuote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "<": result += "\\u003c"
            case ">": result += "\\u003e"
            case "&": result += "\\u0026"
            case "\u{2028}": result += "\\u2028"
            case "\u{2029}": result += "\\u2029"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }

    /// Compact, sorted-key, single-line encoding (one stream-json message per line).
    public var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
