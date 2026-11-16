import Foundation

/// What the indexer reads from one source file: declarations, imports, and the names each
/// declaration calls. Swift, Go, TypeScript/JavaScript and Python are parsed with tree-sitter
/// (`TreeSitterParser`); other languages, and files tree-sitter can't handle, with the
/// line-based rules below: fast and dependency-free, good enough to map a codebase (names
/// resolve to symbols later, by name).
struct ParsedFile: Sendable, Equatable {
    struct Symbol: Sendable, Equatable {
        var name: String
        /// function, method, type, struct, class, interface, enum, protocol, extension, …
        var kind: String
        /// The enclosing type (Swift/Kotlin/Java nesting, a Go receiver, a Python class).
        var container: String
        var line: Int
        var endLine: Int
        var signature: String
        /// Names called inside its body: `foo(` and `x.foo(`.
        var calls: Set<String>
        /// Supertypes, adopted protocols, implemented interfaces, embedded Go structs and
        /// interfaces, as written without generic arguments: `Sendable`, `io.Reader`.
        var inherits: [String] = []
    }

    var language: String
    var symbols: [Symbol]
    var imports: [String]
}

enum CodeParser {
    /// The language of a path, or nil for files that aren't code.
    static func language(of path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if skippedFiles.contains(name) || name.hasSuffix(".min.js") { return nil }
        if ["Makefile", "makefile", "GNUmakefile"].contains(name) { return "makefile" }
        if name == "CODEOWNERS" { return "codeowners" }
        if name == "Dockerfile" || name.hasPrefix("Dockerfile.") || name.hasSuffix(".dockerfile") || name == "Containerfile" { return "dockerfile" }
        switch (path as NSString).pathExtension.lowercased() {
        case "vue": return "vue"
        case "tf", "tfvars", "hcl": return "terraform"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "json": return "json"
        case "mk": return "makefile"
        case "md", "mdx", "markdown": return "markdown"
        case "adoc", "asciidoc": return "asciidoc"
        case "rst": return "rst"
        case "proto": return "protobuf"
        case "graphql", "graphqls", "gql": return "graphql"
        case "sql": return "sql"
        case "prisma": return "prisma"
        default: break
        }
        return switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "go": "go"
        case "ts", "tsx", "mts", "cts": "typescript"
        case "js", "jsx", "mjs", "cjs": "javascript"
        case "py": "python"
        case "rs": "rust"
        case "kt", "kts": "kotlin"
        case "java": "java"
        default: nil
        }
    }

    /// Generated or lock files: big, and nothing to learn from.
    static let skippedFiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "go.sum", "Cargo.lock",
                                            "composer.lock", "Package.resolved", "Gemfile.lock", "poetry.lock", ".terraform.lock.hcl"]

    /// Languages whose files are configuration or documents rather than code.
    static let structured: Set<String> = ["terraform", "yaml", "toml", "json", "makefile", "markdown", "dockerfile", "protobuf", "graphql", "sql", "prisma", "codeowners", "asciidoc", "rst"]

    static func parse(_ text: String, language: String) -> ParsedFile {
        if structured.contains(language) { return StructuredParser.parse(text, language: language) }
        if language == "vue" {
            // A single-file component: its <script> blocks are TypeScript/JavaScript; the
            // template and styles are blanked out so line numbers stay true.
            var inScript = false
            let script = text.components(separatedBy: "\n").map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("<script") { inScript = true; return "" }
                if trimmed.hasPrefix("</script") { inScript = false; return "" }
                return inScript ? line : ""
            }.joined(separator: "\n")
            var parsed = parse(script, language: "typescript")
            parsed.language = "vue"
            return parsed
        }
        guard let tree = TreeSitterParser.parse(text, language: language) else { return parseLines(text, language: language) }
        if tree.clean { return tree.parsed }
        // Tree-sitter recovers from syntax errors (or syntax newer than its grammar), but can
        // lose declarations doing so: the line-based parser wins when it finds more.
        let lines = parseLines(text, language: language)
        return lines.symbols.count > tree.parsed.symbols.count ? lines : tree.parsed
    }

    /// The line-based parser: per-language regular expressions on each line, brace depth
    /// (indentation for Python) for nesting and extents. The fallback for tree-sitter.
    static func parseLines(_ text: String, language: String) -> ParsedFile {
        let lines = text.components(separatedBy: "\n")
        let rules = Rules.for(language)
        var symbols: [ParsedFile.Symbol] = []
        var imports: [String] = []
        // Enclosing types, by the brace depth (or indentation for Python) they opened at.
        var containers: [(name: String, level: Int)] = []
        var depth = 0
        var inGoImportBlock = false

        // Inside a multi-line string literal (triple quotes in Swift, Kotlin, Java and Python,
        // backticks in JS/TS): no declarations or imports there.
        let fences = language == "python" ? ["\"\"\"", "'''"] : ["typescript", "javascript"].contains(language) ? ["`"] : ["\"\"\""]
        var openFence: String?

        for (index, raw) in lines.enumerated() {
            if let fence = openFence {
                if raw.components(separatedBy: fence).count % 2 == 0 { openFence = nil }
                continue
            }
            // An odd number of fences on a line opens a literal that continues below.
            if let fence = fences.first(where: { raw.components(separatedBy: $0).count % 2 == 0 }) {
                openFence = fence
            }
            let line = stripComment(raw, language: language)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let level = language == "python" ? indentation(raw) : depth
            containers.removeAll { $0.level >= level && !trimmed.isEmpty }

            // Imports
            if language == "go" {
                if trimmed.hasPrefix("import (") { inGoImportBlock = true }
                else if inGoImportBlock && trimmed.hasPrefix(")") { inGoImportBlock = false }
                if inGoImportBlock || trimmed.hasPrefix("import ") {
                    if let path = firstMatch(#""([^"]+)""#, in: trimmed) { imports.append(path) }
                }
            } else {
                for pattern in rules.imports {
                    if let name = firstMatch(pattern, in: line) { imports.append(name) }
                }
            }

            // Declarations
            if !trimmed.isEmpty, let declaration = rules.declaration(trimmed, raw: line) {
                var container = declaration.container ?? containers.last?.name ?? ""
                if container == declaration.name { container = "" }
                let kind = declaration.kind == "function" && !container.isEmpty ? "method" : declaration.kind
                symbols.append(ParsedFile.Symbol(
                    name: declaration.name, kind: kind, container: container, line: index + 1,
                    endLine: endLine(from: index, lines: lines, language: language),
                    signature: String(trimmed.prefix(200)), calls: [],
                    inherits: typeKinds.contains(declaration.kind) ? inherits(trimmed, language: language) : []))
                if typeKinds.contains(declaration.kind) {
                    containers.append((declaration.name, level))
                }
            }
            if language != "python" { depth += braceDelta(line) }
        }

        // Calls inside each declaration's body.
        let callPattern = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
        // Only functions and methods: a type's body holds its members, which own their calls.
        for index in symbols.indices where ["function", "method"].contains(symbols[index].kind) {
            let start = symbols[index].line - 1
            let end = min(max(symbols[index].endLine, symbols[index].line), lines.count)
            var calls = Set<String>()
            for (offset, line) in lines[start..<end].enumerated() {
                var code = stripComment(line, language: language)
                // On the declaration line, only what follows the body's opening brace (or the
                // colon of a Python def) counts: not the declaration's own name and parameters.
                if offset == 0 {
                    let opener: Character = language == "python" ? ":" : "{"
                    guard let brace = code.firstIndex(of: opener) else { continue }
                    code = String(code[code.index(after: brace)...])
                }
                let range = NSRange(code.startIndex..., in: code)
                for match in callPattern.matches(in: code, range: range) {
                    if let name = Range(match.range(at: 1), in: code).map({ String(code[$0]) }), !rules.keywords.contains(name) {
                        calls.insert(name)
                    }
                }
            }
            symbols[index].calls = calls
        }
        return ParsedFile(language: language, symbols: symbols, imports: Array(Set(imports)).sorted())
    }

    // MARK: Helpers

    /// Declarations that hold members.
    static let typeKinds: Set<String> = ["type", "struct", "class", "interface", "enum", "protocol", "extension", "actor", "trait", "impl", "object", "record"]

    /// The supertypes named on a type's declaration line: Swift and Kotlin `: A, B`, Java and
    /// TypeScript `extends`/`implements`, Python `class A(B)`, Rust `impl Trait for X`.
    static func inherits(_ declaration: String, language: String) -> [String] {
        var lists: [String] = []
        switch language {
        case "swift":
            let pattern = #"\b(?:class|struct|enum|protocol|actor|extension)\s+[\w.]+\s*(?:<[^>]*>)?\s*:\s*(.+?)\s*(?:\bwhere\b|\{|$)"#
            if let list = firstMatch(pattern, in: declaration) { lists.append(list) }
        case "kotlin":
            let pattern = #"\b(?:class|interface|object)\s+\w+\s*(?:<[^>]*>)?\s*(?:(?:public|private|protected|internal)?\s*(?:constructor)?\s*\(.*\))?\s*:\s*(.+?)\s*(?:\bwhere\b|\{|$)"#
            if let list = firstMatch(pattern, in: declaration) { lists.append(list) }
        case "java", "typescript", "javascript":
            if let list = firstMatch(#"\bextends\s+(.+?)\s*(?:\bimplements\b|\{|$)"#, in: declaration) { lists.append(list) }
            if let list = firstMatch(#"\bimplements\s+(.+?)\s*(?:\{|$)"#, in: declaration) { lists.append(list) }
        case "python":
            if let list = firstMatch(#"^class\s+\w+\s*\((.*)\)\s*:"#, in: declaration) { lists.append(list) }
        case "rust":
            if let name = firstMatch(#"^(?:unsafe\s+)?impl(?:<[^>]*>)?\s+([\w:]+)(?:<[^>]*>)?\s+for\s+"#, in: declaration) { lists.append(name) }
        default: break
        }
        return lists.flatMap { list -> [String] in
            // Generic and constructor arguments go first: their commas don't separate supertypes.
            var flat = list
            while let range = flat.range(of: #"<[^<>]*>|\([^()]*\)"#, options: .regularExpression) { flat.removeSubrange(range) }
            return flat.split(separator: ",").compactMap { item -> String? in
                // Without attributes (`@unchecked Sendable`); keyword arguments (`metaclass=M`) aren't types.
                let words = item.split(separator: " ").filter { !$0.hasPrefix("@") }
                guard !item.contains("="), let name = words.last.map(String.init),
                      name.range(of: #"^[A-Za-z_$][\w$.:]*$"#, options: .regularExpression) != nil else { return nil }
                return name
            }
        }
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// Where a declaration ends: its braces balance (C-like languages) or the indentation
    /// returns to its level (Python). Declarations without a body end on their own line.
    private static func endLine(from start: Int, lines: [String], language: String) -> Int {
        if language == "python" {
            let base = indentation(lines[start])
            var last = start
            for index in (start + 1)..<lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if indentation(line) <= base { break }
                last = index
            }
            return last + 1
        }
        var depth = 0
        var opened = false
        for index in start..<min(lines.count, start + 4000) {
            let code = stripComment(lines[index], language: language)
            let delta = braceDelta(code)
            if stripStrings(code).contains("{") { opened = true }
            depth += delta
            if opened && depth <= 0 { return index + 1 }
            // A body never opened within a few lines: a one-line declaration.
            if !opened && index - start >= 3 { return start + 1 }
        }
        return opened ? min(lines.count, start + 4000) : start + 1
    }

    private static func braceDelta(_ line: String) -> Int {
        stripStrings(line).reduce(0) { $0 + ($1 == "{" ? 1 : $1 == "}" ? -1 : 0) }
    }

    /// The line without string and character literals (rough: no escapes across lines).
    private static func stripStrings(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func stripComment(_ line: String, language: String) -> String {
        let marker = language == "python" ? "#" : "//"
        guard let range = line.range(of: marker) else { return line }
        // Only when the marker isn't inside a string.
        let before = line[..<range.lowerBound]
        return before.filter { $0 == "\"" }.count % 2 == 0 ? String(before) : line
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Per-language rules

    struct Declaration {
        var name: String
        var kind: String
        var container: String?
    }

    struct Rules {
        var imports: [String]
        var keywords: Set<String>
        /// Patterns tried in order: (regex, kind, name group, optional container group).
        var declarations: [(NSRegularExpression, String, Int, Int?)]

        func declaration(_ trimmed: String, raw: String) -> Declaration? {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for (regex, kind, nameGroup, containerGroup) in declarations {
                guard let match = regex.firstMatch(in: trimmed, range: range),
                      let nameRange = Range(match.range(at: nameGroup), in: trimmed) else { continue }
                let name = String(trimmed[nameRange])
                guard !keywords.contains(name) || name == "init" else { continue }
                // "keyword": the declaring keyword (group 1) is the kind, e.g. struct or protocol.
                let kind = kind == "keyword" ? Range(match.range(at: 1), in: trimmed).map { String(trimmed[$0]) } ?? "type" : kind
                let container = containerGroup.flatMap { Range(match.range(at: $0), in: trimmed) }.map { String(trimmed[$0]) }
                return Declaration(name: name, kind: kind, container: container)
            }
            return nil
        }

        private static func compile(_ items: [(String, String, Int, Int?)]) -> [(NSRegularExpression, String, Int, Int?)] {
            items.map { (try! NSRegularExpression(pattern: $0.0), $0.1, $0.2, $0.3) }
        }

        static let common: Set<String> = ["if", "for", "while", "switch", "catch", "return", "guard", "else", "do", "try", "await",
                                          "throw", "new", "super", "self", "this", "func", "function", "fn", "def", "print",
                                          "sizeof", "typeof", "assert", "defer", "go", "select", "case", "when", "match"]

        static func `for`(_ language: String) -> Rules {
            switch language {
            case "swift": swift
            case "go": go
            case "typescript", "javascript": typescript
            case "python": python
            case "rust": rust
            case "kotlin": kotlin
            case "java": java
            default: Rules(imports: [], keywords: common, declarations: [])
            }
        }

        private static let swiftModifiers = #"(?:(?:@\w+(?:\([^)]*\))?|public|private|internal|fileprivate|open|static|final|override|mutating|nonmutating|nonisolated|convenience|required|lazy|indirect|dynamic|package|class(?=\s+(?:func|var)))\s+)*"#
        static let swift = Rules(
            imports: [#"^\s*(?:@\w+\s+)?import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?([\w.]+)"#],
            keywords: common.union(["init", "deinit", "subscript", "get", "set", "willSet", "didSet", "some", "any", "where"]),
            declarations: compile([
                ("^" + swiftModifiers + #"func\s+([A-Za-z_][\w]*|[^\s(<]+)"#, "function", 1, nil),
                ("^" + swiftModifiers + #"(init)[?!]?\s*[(<]"#, "function", 1, nil),
                ("^" + swiftModifiers + #"(class|struct|enum|protocol|actor)\s+([A-Za-z_]\w*)"#, "keyword", 2, nil),
                ("^" + swiftModifiers + #"extension\s+([A-Za-z_][\w.]*)"#, "extension", 1, nil),
                ("^" + swiftModifiers + #"typealias\s+([A-Za-z_]\w*)"#, "typealias", 1, nil),
            ]))

        static let go = Rules(
            imports: [],
            keywords: common.union(["make", "len", "cap", "append", "panic", "recover", "copy", "delete", "close", "new", "string", "int", "byte", "error"]),
            declarations: compile([
                (#"^func\s+\(\s*\w+\s+\*?([A-Za-z_]\w*)(?:\[[^\]]*\])?\s*\)\s*([A-Za-z_]\w*)"#, "method", 2, 1),
                (#"^func\s+([A-Za-z_]\w*)"#, "function", 1, nil),
                (#"^type\s+([A-Za-z_]\w*)(?:\[[^\]]*\])?\s+struct\b"#, "struct", 1, nil),
                (#"^type\s+([A-Za-z_]\w*)(?:\[[^\]]*\])?\s+interface\b"#, "interface", 1, nil),
                (#"^type\s+([A-Za-z_]\w*)"#, "typealias", 1, nil),
            ]))

        static let typescript = Rules(
            imports: [#"\bfrom\s+['"]([^'"]+)['"]"#, #"\brequire\(\s*['"]([^'"]+)['"]\s*\)"#, #"^\s*import\s+['"]([^'"]+)['"]"#],
            keywords: common.union(["constructor", "import", "require", "export", "async", "then", "catch", "map", "filter", "forEach", "push"]),
            declarations: compile([
                (#"^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s+([A-Za-z_$][\w$]*)"#, "function", 1, nil),
                (#"^(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)"#, "class", 1, nil),
                (#"^(?:export\s+)?interface\s+([A-Za-z_$][\w$]*)"#, "interface", 1, nil),
                (#"^(?:export\s+)?(?:declare\s+)?type\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*="#, "typealias", 1, nil),
                (#"^(?:export\s+)?(?:const\s+)?enum\s+([A-Za-z_$][\w$]*)"#, "enum", 1, nil),
                (#"^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|[A-Za-z_$][\w$]*\s*=>)"#, "function", 1, nil),
                (#"^(?:(?:public|private|protected|static|readonly|async|override|abstract|get|set)\s+)*([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\([^)]*\)?\s*(?::\s*[^{=]+)?\{\s*$"#, "method", 1, nil),
            ]))

        static let python = Rules(
            imports: [#"^\s*import\s+([\w.]+)"#, #"^\s*from\s+([\w.]+)\s+import\b"#],
            keywords: common.union(["len", "str", "int", "dict", "list", "set", "range", "isinstance", "super", "print", "open"]),
            declarations: compile([
                (#"^(?:async\s+)?def\s+([A-Za-z_]\w*)"#, "function", 1, nil),
                (#"^class\s+([A-Za-z_]\w*)"#, "class", 1, nil),
            ]))

        static let rust = Rules(
            imports: [#"^\s*(?:pub\s+)?use\s+([\w:]+)"#],
            keywords: common.union(["Some", "Ok", "Err", "None", "vec", "format", "println", "unwrap", "clone", "into", "iter", "Box", "Vec"]),
            declarations: compile([
                (#"^(?:pub(?:\([^)]*\))?\s+)?(?:const\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+"[^"]*"\s+)?fn\s+([A-Za-z_]\w*)"#, "function", 1, nil),
                (#"^(?:pub(?:\([^)]*\))?\s+)?struct\s+([A-Za-z_]\w*)"#, "struct", 1, nil),
                (#"^(?:pub(?:\([^)]*\))?\s+)?enum\s+([A-Za-z_]\w*)"#, "enum", 1, nil),
                (#"^(?:pub(?:\([^)]*\))?\s+)?(?:unsafe\s+)?trait\s+([A-Za-z_]\w*)"#, "trait", 1, nil),
                (#"^(?:unsafe\s+)?impl(?:<[^>]*>)?\s+(?:[\w:<>, ]+\s+for\s+)?([A-Za-z_]\w*)"#, "impl", 1, nil),
                (#"^(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z_]\w*)"#, "module", 1, nil),
            ]))

        static let kotlin = Rules(
            imports: [#"^\s*import\s+([\w.]+)"#],
            keywords: common.union(["listOf", "mapOf", "setOf", "println", "require", "check", "let", "also", "apply", "run", "with"]),
            declarations: compile([
                (#"^(?:(?:public|private|protected|internal|override|open|abstract|suspend|inline|operator|infix|tailrec|external)\s+)*fun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?([A-Za-z_]\w*)"#, "function", 1, nil),
                (#"^(?:(?:public|private|protected|internal|open|abstract|sealed|data|enum|inner|annotation|value)\s+)*(?:class|interface|object)\s+([A-Za-z_]\w*)"#, "class", 1, nil),
            ]))

        static let java = Rules(
            imports: [#"^\s*import\s+(?:static\s+)?([\w.]+)"#],
            keywords: common.union(["println", "equals", "hashCode", "toString", "valueOf"]),
            declarations: compile([
                (#"^(?:(?:public|private|protected|static|final|abstract|sealed|non-sealed|strictfp)\s+)*(?:class|interface|enum|record|@interface)\s+([A-Za-z_]\w*)"#, "class", 1, nil),
                (#"^(?:(?:public|private|protected|static|final|abstract|synchronized|native|default)\s+)+(?:<[^>]*>\s*)?[\w<>\[\],.? ]+\s+([A-Za-z_]\w*)\s*\("#, "method", 1, nil),
            ]))
    }
}
