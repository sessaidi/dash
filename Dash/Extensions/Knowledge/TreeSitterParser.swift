import Foundation
import SwiftTreeSitter
import TreeSitterGo
import TreeSitterPython
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

/// Parses Swift, Go, TypeScript/JavaScript and Python with tree-sitter: exact declaration
/// extents, containers (Go receivers too), calls, supertypes and imports, in the same shape and
/// with the same conventions (kinds, container names) as the line-based parser, so symbol ids
/// stay stable. One query per grammar finds the nodes; the code below reads names off them.
///
/// Thread-safe: a `Parser` is made per call (tree-sitter parsers aren't), the compiled queries
/// are immutable and shared.
enum TreeSitterParser {
    /// A parse result, and whether the tree came out without syntax errors.
    struct Result {
        var parsed: ParsedFile
        var clean: Bool
    }

    static let languages: Set<String> = ["swift", "go", "typescript", "javascript", "python"]

    /// The file parsed with tree-sitter, or nil when the language isn't supported or the grammar
    /// can't be loaded. TypeScript is tried with the TSX grammar when it doesn't parse cleanly
    /// (and JavaScript the other way round), since the path doesn't tell whether there's JSX.
    static func parse(_ text: String, language: String) -> Result? {
        let grammars: [Grammar] = switch language {
        case "swift": [.swift]
        case "go": [.go]
        case "typescript": [.typescript, .tsx]
        case "javascript": [.tsx, .typescript]
        case "python": [.python]
        default: []
        }
        var first: Result?
        for grammar in grammars {
            guard let result = parse(text, language: language, grammar: grammar) else { continue }
            if result.clean { return result }
            first = first ?? result
        }
        return first
    }

    private static func parse(_ text: String, language: String, grammar: Grammar) -> Result? {
        guard let query = grammar.query else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar.language)) != nil,
              // Grammars such as Go's expect the last line to end: one more newline changes no line.
              let tree = parser.parse(text.hasSuffix("\n") ? text : text + "\n"), let root = tree.rootNode else { return nil }
        let source = Source(text: text)
        let keywords = CodeParser.Rules.for(language).keywords

        var definitions: [(node: Node, role: String)] = []
        var calls: [(offset: UInt32, name: String)] = []
        var imports = Set<String>()
        for match in query.execute(in: tree) {
            for capture in match.captures {
                switch capture.name {
                case "call":
                    let name = source.text(capture.node)
                    if !keywords.contains(name) { calls.append((capture.node.byteRange.lowerBound, name)) }
                case "import":
                    imports.insert(unquote(source.text(capture.node)))
                case "import.dynamic":
                    // `require("x")` or `import("x")`: the callee is captured as `require`.
                    if let callee = match.captures(named: "require").first, ["require", "import"].contains(source.text(callee.node)) {
                        imports.insert(source.text(capture.node))
                    }
                case "import.future":
                    imports.insert("__future__")
                case "require": break
                case let role?:
                    definitions.append((capture.node, role))
                case nil: break
                }
            }
        }
        calls.sort { $0.offset < $1.offset }

        let reader = Reader(family: grammar.family, source: source)
        var symbols: [(order: UInt32, symbol: ParsedFile.Symbol)] = []
        for (node, role) in definitions {
            guard let definition = reader.definition(node, role: role),
                  !keywords.contains(definition.name) || definition.name == "init" else { continue }
            var container = definition.container ?? reader.container(of: node) ?? ""
            if container == definition.name { container = "" }
            let kind = definition.kind == "function" && !container.isEmpty ? "method" : definition.kind
            let anchor = definition.anchor ?? node
            let start = anchor.pointRange.lowerBound.row
            let end = node.pointRange.upperBound
            // A node ending at the start of a line ends on the line before.
            let endRow = end.column == 0 && end.row > start ? end.row : end.row + 1
            var symbol = ParsedFile.Symbol(
                name: definition.name, kind: kind, container: container, line: Int(start) + 1, endLine: Int(endRow),
                signature: String(source.line(Int(start)).trimmingCharacters(in: .whitespaces).prefix(160)),
                calls: [], inherits: definition.inherits)
            if ["function", "method"].contains(kind), let body = definition.body {
                symbol.calls = names(in: body.byteRange, calls: calls)
            }
            symbols.append((anchor.byteRange.lowerBound, symbol))
        }
        symbols.sort { $0.order < $1.order }
        return Result(parsed: ParsedFile(language: language, symbols: symbols.map(\.symbol), imports: imports.sorted()),
                      clean: !root.hasError)
    }

    /// The names called within a byte range, from the calls sorted by offset.
    private static func names(in range: Range<UInt32>, calls: [(offset: UInt32, name: String)]) -> Set<String> {
        var low = 0, high = calls.count
        while low < high {
            let middle = (low + high) / 2
            if calls[middle].offset < range.lowerBound { low = middle + 1 } else { high = middle }
        }
        var names = Set<String>()
        while low < calls.count, calls[low].offset < range.upperBound {
            names.insert(calls[low].name)
            low += 1
        }
        return names
    }

    private static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }

    // MARK: Grammars

    enum Family: Sendable { case swift, go, typescript, python }

    struct Grammar: Sendable {
        let language: Language
        let family: Family
        /// Nil when the query doesn't compile against the grammar: the line-based parser takes over.
        let query: Query?

        init(_ language: OpaquePointer, family: Family) {
            self.language = Language(language: language)
            self.family = family
            self.query = try? Query(language: self.language, data: Data(Self.queries[family, default: ""].utf8))
        }

        static let swift = Grammar(tree_sitter_swift(), family: .swift)
        static let go = Grammar(tree_sitter_go(), family: .go)
        static let typescript = Grammar(tree_sitter_typescript(), family: .typescript)
        static let tsx = Grammar(tree_sitter_tsx(), family: .typescript)
        static let python = Grammar(tree_sitter_python(), family: .python)

        /// Captures: a definition by its role (`type`, `function`, `typealias`), `import`,
        /// `call` (the called name: `foo` in `foo()` and `x.foo()`).
        static let queries: [Family: String] = [
            .swift: """
                (class_declaration) @type
                (protocol_declaration) @type
                (function_declaration) @function
                (protocol_function_declaration) @function
                (init_declaration) @function
                (typealias_declaration) @typealias
                (import_declaration (identifier) @import)
                (call_expression . (simple_identifier) @call)
                (call_expression . (navigation_expression suffix: (navigation_suffix suffix: (simple_identifier) @call)))
                """,
            .go: """
                (function_declaration) @function
                (method_declaration) @function
                (type_spec) @type
                (type_alias) @typealias
                (import_spec path: (_) @import)
                (call_expression function: (identifier) @call)
                (call_expression function: (selector_expression field: (field_identifier) @call))
                """,
            .typescript: """
                (function_declaration) @function
                (generator_function_declaration) @function
                (method_definition) @function
                (variable_declarator value: [(arrow_function) (function_expression)]) @function
                (class_declaration) @type
                (abstract_class_declaration) @type
                (interface_declaration) @type
                (enum_declaration) @type
                (type_alias_declaration) @typealias
                (import_statement source: (string (string_fragment) @import))
                (export_statement source: (string (string_fragment) @import))
                (call_expression function: [(identifier) (import)] @require arguments: (arguments . (string (string_fragment) @import.dynamic)))
                (call_expression function: (identifier) @call)
                (call_expression function: (member_expression property: (property_identifier) @call))
                (new_expression constructor: (identifier) @call)
                """,
            .python: """
                (function_definition) @function
                (class_definition) @type
                (import_statement name: (dotted_name) @import)
                (import_statement name: (aliased_import name: (dotted_name) @import))
                (import_from_statement module_name: (_) @import)
                (future_import_statement) @import.future
                (call function: (identifier) @call)
                (call function: (attribute attribute: (identifier) @call))
                """,
        ]
    }

    // MARK: Reading nodes

    /// The source text, addressed by the UTF-16 ranges tree-sitter reports for a Swift string.
    struct Source {
        let string: NSString
        let lines: [String]

        init(text: String) {
            string = text as NSString
            lines = text.components(separatedBy: "\n")
        }

        func text(_ node: Node) -> String {
            let range = node.range
            guard range.location != NSNotFound, NSMaxRange(range) <= string.length else { return "" }
            return string.substring(with: range)
        }

        func line(_ row: Int) -> String {
            row < lines.count ? lines[row] : ""
        }
    }

    struct Definition {
        var name: String
        var kind: String
        /// Set when the declaration names it (a Go receiver), else the enclosing type.
        var container: String?
        /// The node whose line is the declaration's line: its name, past attributes and decorators.
        var anchor: Node?
        /// Where its calls are: the body of a function.
        var body: Node?
        var inherits: [String] = []
    }

    struct Reader {
        let family: Family
        let source: Source

        func definition(_ node: Node, role: String) -> Definition? {
            switch family {
            case .swift: swift(node, role: role)
            case .go: go(node, role: role)
            case .typescript: typescript(node, role: role)
            case .python: python(node, role: role)
            }
        }

        /// The name of the nearest enclosing type.
        func container(of node: Node) -> String? {
            var current = node.parent
            while let ancestor = current {
                if containerTypes.contains(ancestor.nodeType ?? ""), let name = typeName(ancestor) { return name }
                current = ancestor.parent
            }
            return nil
        }

        private var containerTypes: Set<String> {
            switch family {
            case .swift: ["class_declaration", "protocol_declaration"]
            case .go: []
            case .typescript: ["class_declaration", "abstract_class_declaration", "interface_declaration", "enum_declaration"]
            case .python: ["class_definition"]
            }
        }

        private func typeName(_ node: Node) -> String? {
            node.child(byFieldName: "name").map { withoutGenerics(text($0)) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        private func text(_ node: Node) -> String { source.text(node) }

        private func children(_ node: Node) -> [Node] {
            (0..<node.childCount).compactMap { node.child(at: $0) }
        }

        private func namedChildren(_ node: Node) -> [Node] {
            (0..<node.namedChildCount).compactMap { node.namedChild(at: $0) }
        }

        /// `Base<T>` → `Base`, `*pkg.T[K]` → `pkg.T`, whitespace collapsed.
        private func withoutGenerics(_ name: String) -> String {
            var name = name
            if let cut = name.firstIndex(where: { $0 == "<" || $0 == "[" || $0 == "(" }) { name = String(name[..<cut]) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "*&").union(.whitespacesAndNewlines))
            return name.filter { !$0.isWhitespace }
        }

        // MARK: Swift

        private func swift(_ node: Node, role: String) -> Definition? {
            switch node.nodeType {
            case "class_declaration", "protocol_declaration":
                guard let nameNode = node.child(byFieldName: "name") else { return nil }
                let keywords: Set<String> = ["class", "struct", "enum", "actor", "extension"]
                let kind = node.nodeType == "protocol_declaration"
                    ? "protocol" : children(node).first { !$0.isNamed && keywords.contains($0.nodeType ?? "") }?.nodeType ?? "class"
                let inherits = children(node).filter { $0.nodeType == "inheritance_specifier" }
                    .compactMap { $0.child(byFieldName: "inherits_from").map { withoutGenerics(text($0)) } }
                    .filter { !$0.isEmpty }
                return Definition(name: withoutGenerics(text(nameNode)), kind: kind, anchor: nameNode, inherits: inherits)
            case "function_declaration", "protocol_function_declaration":
                // The name follows `func`: an identifier, or an operator such as `==`.
                let all = children(node)
                guard let keyword = all.firstIndex(where: { $0.nodeType == "func" }), keyword + 1 < all.count else { return nil }
                let nameNode = all[keyword + 1]
                return Definition(name: text(nameNode), kind: "function", anchor: nameNode, body: node.child(byFieldName: "body"))
            case "init_declaration":
                let keyword = children(node).first { $0.nodeType == "init" }
                return Definition(name: "init", kind: "function", anchor: keyword, body: node.child(byFieldName: "body"))
            case "typealias_declaration":
                guard let nameNode = node.child(byFieldName: "name") else { return nil }
                return Definition(name: text(nameNode), kind: "typealias", anchor: nameNode)
            default:
                return nil
            }
        }

        // MARK: Go

        private func go(_ node: Node, role: String) -> Definition? {
            guard let nameNode = node.child(byFieldName: "name") else { return nil }
            let name = text(nameNode)
            switch node.nodeType {
            case "function_declaration":
                return Definition(name: name, kind: "function", anchor: nameNode, body: node.child(byFieldName: "body"))
            case "method_declaration":
                // The receiver's type: `(s *Service)`, `(s Set[T])`.
                let receiver = node.child(byFieldName: "receiver")
                    .flatMap { namedChildren($0).first { $0.nodeType == "parameter_declaration" } }
                    .flatMap { $0.child(byFieldName: "type") }
                    .map { withoutGenerics(text($0)) }
                return Definition(name: name, kind: "method", container: receiver ?? "", anchor: nameNode, body: node.child(byFieldName: "body"))
            case "type_spec":
                let type = node.child(byFieldName: "type")
                switch type?.nodeType {
                case "struct_type":
                    // Embedded fields: a type without a field name.
                    let fields = type.flatMap { namedChildren($0).first { $0.nodeType == "field_declaration_list" } }.map(namedChildren) ?? []
                    let embedded = fields.filter { $0.nodeType == "field_declaration" && $0.child(byFieldName: "name") == nil }
                        .compactMap { $0.child(byFieldName: "type").map { withoutGenerics(text($0)) } }
                    return Definition(name: name, kind: "struct", container: "", anchor: nameNode, inherits: embedded)
                case "interface_type":
                    // Embedded interfaces; not type-set constraints such as `~int | ~string`.
                    let embedded = (type.map(namedChildren) ?? []).filter { $0.nodeType == "type_elem" }
                        .map { text($0) }.filter { !$0.contains("|") && !$0.contains("~") }.map(withoutGenerics)
                    return Definition(name: name, kind: "interface", container: "", anchor: nameNode, inherits: embedded)
                default:
                    return Definition(name: name, kind: "typealias", container: "", anchor: nameNode)
                }
            case "type_alias":
                return Definition(name: name, kind: "typealias", container: "", anchor: nameNode)
            default:
                return nil
            }
        }

        // MARK: TypeScript and JavaScript

        private func typescript(_ node: Node, role: String) -> Definition? {
            guard let nameNode = node.child(byFieldName: "name") else { return nil }
            let name = text(nameNode)
            switch node.nodeType {
            case "function_declaration", "generator_function_declaration":
                return Definition(name: name, kind: "function", anchor: nameNode, body: node.child(byFieldName: "body"))
            case "method_definition":
                return Definition(name: name, kind: "method", anchor: nameNode, body: node.child(byFieldName: "body"))
            case "variable_declarator":
                guard nameNode.nodeType == "identifier" else { return nil }
                return Definition(name: name, kind: "function", anchor: nameNode, body: node.child(byFieldName: "value")?.child(byFieldName: "body"))
            case "class_declaration", "abstract_class_declaration":
                var inherits: [String] = []
                for heritage in namedChildren(node) where heritage.nodeType == "class_heritage" {
                    for clause in namedChildren(heritage) {
                        switch clause.nodeType {
                        case "extends_clause":
                            inherits += children(clause).enumerated()
                                .filter { clause.fieldNameForChild(at: $0.offset) == "value" }.map { withoutGenerics(text($0.element)) }
                        case "implements_clause":
                            inherits += namedChildren(clause).map { withoutGenerics(text($0)) }
                        default: break
                        }
                    }
                }
                return Definition(name: name, kind: "class", anchor: nameNode, inherits: inherits.filter { !$0.isEmpty })
            case "interface_declaration":
                let inherits = namedChildren(node).filter { $0.nodeType == "extends_type_clause" }
                    .flatMap(namedChildren).map { withoutGenerics(text($0)) }.filter { !$0.isEmpty }
                return Definition(name: name, kind: "interface", anchor: nameNode, inherits: inherits)
            case "enum_declaration":
                return Definition(name: name, kind: "enum", anchor: nameNode)
            case "type_alias_declaration":
                return Definition(name: name, kind: "typealias", anchor: nameNode)
            default:
                return nil
            }
        }

        // MARK: Python

        private func python(_ node: Node, role: String) -> Definition? {
            guard let nameNode = node.child(byFieldName: "name") else { return nil }
            let name = text(nameNode)
            switch node.nodeType {
            case "function_definition":
                return Definition(name: name, kind: "function", anchor: nameNode, body: node.child(byFieldName: "body"))
            case "class_definition":
                // Base classes, not keyword arguments such as `metaclass=ABCMeta`.
                let inherits = (node.child(byFieldName: "superclasses").map(namedChildren) ?? [])
                    .filter { ["identifier", "attribute"].contains($0.nodeType ?? "") }.map { text($0) }
                return Definition(name: name, kind: "class", anchor: nameNode, inherits: inherits)
            default:
                return nil
            }
        }
    }
}
