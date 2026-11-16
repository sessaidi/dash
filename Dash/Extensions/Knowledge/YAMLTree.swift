import Foundation

/// A YAML value as configuration files write it: block mappings and sequences by indentation,
/// scalars without their quotes, `[a, b]` flow lists, `|`/`>` block scalars as text. Enough to
/// read manifests, Helm values and CI files by structure. Anchors, aliases, tags and flow
/// collections spanning lines aren't resolved; what can't be read is skipped, never fatal.
struct YAMLNode: Sendable {
    enum Value: Sendable {
        case scalar(String)
        case map([(key: String, node: YAMLNode)])
        case list([YAMLNode])
    }

    var value: Value
    /// The 1-based line it starts on, in the whole file.
    var line: Int

    subscript(key: String) -> YAMLNode? {
        if case .map(let entries) = value { return entries.first { $0.key == key }?.node }
        return nil
    }

    /// The node at a path of keys: `node.at("spec", "template", "spec")`.
    func at(_ keys: String...) -> YAMLNode? {
        var current: YAMLNode? = self
        for key in keys { current = current?[key] }
        return current
    }

    /// A non-empty scalar's text.
    var string: String? {
        if case .scalar(let text) = value, !text.isEmpty, text != "~", text != "null" { return text }
        return nil
    }

    var entries: [(key: String, node: YAMLNode)] {
        if case .map(let entries) = value { return entries }
        return []
    }

    var items: [YAMLNode] {
        if case .list(let items) = value { return items }
        return []
    }

    var isMap: Bool { if case .map = value { true } else { false } }

    /// A list's scalar items, or the scalar itself.
    var strings: [String] {
        if let string { return [string] }
        return items.compactMap(\.string)
    }
}

enum YAMLTree {
    /// The documents of a file (split at `---`), each as its root node.
    static func documents(_ text: String) -> [YAMLNode] {
        var result: [YAMLNode] = []
        var current: [String] = []
        var start = 1
        let lines = text.components(separatedBy: "\n")
        func flush(next: Int) {
            var reader = Reader(lines: current, first: start)
            if let node = reader.node(minIndent: 0) { result.append(node) }
            current = []
            start = next
        }
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("---") || line.hasPrefix("...") && line.trimmingCharacters(in: .whitespaces) == "..." {
                flush(next: index + 2)
            } else {
                current.append(line.hasSuffix("\r") ? String(line.dropLast()) : line)
            }
        }
        flush(next: lines.count + 1)
        return result
    }

    /// The first document's root.
    static func parse(_ text: String) -> YAMLNode? { documents(text).first }

    private struct Reader {
        var lines: [String]
        let first: Int
        var index = 0

        init(lines: [String], first: Int) {
            self.lines = lines
            self.first = first
        }

        mutating func node(minIndent: Int) -> YAMLNode? {
            skipBlank()
            guard index < lines.count else { return nil }
            let indent = Self.indent(lines[index])
            guard indent >= minIndent else { return nil }
            let content = Self.content(lines[index], indent: indent)
            if Self.isItem(content) { return list(indent: indent) }
            if Self.split(content) != nil { return map(indent: indent) }
            let line = first + index
            index += 1
            return YAMLNode(value: .scalar(Self.scalar(content)), line: line)
        }

        private mutating func list(indent: Int) -> YAMLNode {
            let line = first + index
            var items: [YAMLNode] = []
            while true {
                skipBlank()
                guard index < lines.count, Self.indent(lines[index]) == indent else { break }
                let content = Self.content(lines[index], indent: indent)
                guard Self.isItem(content) else { break }
                if content == "-" {
                    let itemLine = first + index
                    index += 1
                    items.append(node(minIndent: indent + 1) ?? YAMLNode(value: .scalar(""), line: itemLine))
                    continue
                }
                // "- key: value" is a mapping indented past the dash: blank the dash and read it so.
                var characters = Array(lines[index])
                characters[indent] = " "
                lines[index] = String(characters)
                let itemLine = first + index
                items.append(node(minIndent: indent + 1) ?? YAMLNode(value: .scalar(""), line: itemLine))
            }
            return YAMLNode(value: .list(items), line: line)
        }

        private mutating func map(indent: Int) -> YAMLNode {
            let line = first + index
            var entries: [(key: String, node: YAMLNode)] = []
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let current = Self.indent(lines[index])
                if current < indent { break }
                let content = Self.content(lines[index], indent: current)
                // Deeper lines nothing claimed: the rest of a multi-line scalar.
                if current > indent { index += 1; continue }
                guard let (key, rest) = Self.split(content) else {
                    if Self.isItem(content) { break }
                    index += 1
                    continue
                }
                let keyLine = first + index
                index += 1
                entries.append((key, value(rest, indent: indent, line: keyLine)))
            }
            return YAMLNode(value: .map(entries), line: line)
        }

        /// What follows a key: a nested block, a block scalar, a flow list or a scalar.
        private mutating func value(_ rest: String, indent: Int, line: Int) -> YAMLNode {
            let rest = Self.withoutProperties(rest)
            if rest.isEmpty {
                skipBlank()
                guard index < lines.count else { return YAMLNode(value: .scalar(""), line: line) }
                let next = Self.indent(lines[index])
                if next > indent || (next == indent && Self.isItem(Self.content(lines[index], indent: next))) {
                    return node(minIndent: next) ?? YAMLNode(value: .scalar(""), line: line)
                }
                return YAMLNode(value: .scalar(""), line: line)
            }
            if rest.range(of: #"^[|>][-+0-9]*$"#, options: .regularExpression) != nil {
                return YAMLNode(value: .scalar(blockScalar(indent: indent, folded: rest.hasPrefix(">"))), line: line)
            }
            if rest.hasPrefix("[") {
                var text = rest
                while !Self.balanced(text), index < lines.count, Self.indent(lines[index]) > indent {
                    text += " " + Self.content(lines[index], indent: Self.indent(lines[index]))
                    index += 1
                }
                let inner = text.dropFirst().prefix { $0 != "]" }
                let items = SourceScan.splitTopLevel(String(inner), separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    .map { YAMLNode(value: .scalar(Self.scalar($0)), line: line) }
                return YAMLNode(value: .list(items), line: line)
            }
            if rest.hasPrefix("{") {
                let inner = rest.dropFirst().prefix { $0 != "}" }
                var entries: [(key: String, node: YAMLNode)] = []
                for part in SourceScan.splitTopLevel(String(inner), separator: ",") {
                    guard let (key, value) = Self.split(part.trimmingCharacters(in: .whitespaces)) else { continue }
                    entries.append((key, YAMLNode(value: .scalar(Self.scalar(value)), line: line)))
                }
                return YAMLNode(value: .map(entries), line: line)
            }
            return YAMLNode(value: .scalar(Self.scalar(rest)), line: line)
        }

        /// The lines of a `|` or `>` scalar: everything indented past its key.
        private mutating func blockScalar(indent: Int, folded: Bool) -> String {
            var body: [String] = []
            while index < lines.count {
                let line = lines[index]
                if !line.trimmingCharacters(in: .whitespaces).isEmpty, Self.indent(line) <= indent { break }
                body.append(line)
                index += 1
            }
            while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            let margin = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(Self.indent).min() ?? 0
            let trimmed = body.map { $0.count >= margin ? String($0.dropFirst(margin)) : "" }
            return trimmed.joined(separator: folded ? " " : "\n")
        }

        private mutating func skipBlank() {
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || trimmed.hasPrefix("#") else { return }
                index += 1
            }
        }

        static func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }

        static func isItem(_ content: String) -> Bool { content == "-" || content.hasPrefix("- ") }

        /// The line past its indentation, without a trailing comment.
        static func content(_ line: String, indent: Int) -> String {
            var result = ""
            var quote: Character?
            var previous: Character = " "
            for character in line.dropFirst(indent) {
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'", previous == " " || previous == ":" || previous == "[" || previous == "," || previous == "-" {
                    quote = character
                } else if character == "#", previous == " " || previous == "\t" {
                    break
                }
                result.append(character)
                previous = character
            }
            return result.trimmingCharacters(in: .whitespaces)
        }

        /// "key: rest" (the key unquoted), nil when the line isn't a mapping entry.
        static func split(_ content: String) -> (String, String)? {
            guard !content.isEmpty, !isItem(content) else { return nil }
            var quote: Character?
            var index = content.startIndex
            if let first = content.first, first == "\"" || first == "'" { quote = first; index = content.index(after: index) }
            while index < content.endIndex {
                let character = content[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == ":" {
                    let next = content.index(after: index)
                    if next == content.endIndex || content[next] == " " || content[next] == "\t" {
                        let key = scalar(String(content[..<index]))
                        guard !key.isEmpty, !key.hasPrefix("{"), !key.hasPrefix("[") else { return nil }
                        return (key, String(content[next...]).trimmingCharacters(in: .whitespaces))
                    }
                }
                index = content.index(after: index)
            }
            return nil
        }

        /// A scalar without its quotes (simple escapes of double-quoted ones read).
        static func scalar(_ raw: String) -> String {
            let text = withoutProperties(raw.trimmingCharacters(in: .whitespaces))
            guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
            let inner = String(text.dropFirst().dropLast())
            if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
            return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\")
        }

        /// Without a leading `&anchor` or `!tag`.
        static func withoutProperties(_ text: String) -> String {
            var text = Substring(text)
            while let first = text.first, first == "&" || first == "!" {
                text = text.drop { $0 != " " }.drop { $0 == " " }
            }
            return String(text)
        }

        static func balanced(_ text: String) -> Bool {
            text.filter { $0 == "[" }.count <= text.filter { $0 == "]" }.count
        }
    }
}
