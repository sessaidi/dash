import SwiftUI

/// Colours code for notes and chat: comments, strings, numbers, keywords, types, function calls,
/// per language (Swift, Go, TypeScript/JavaScript, Python, Rust, Kotlin, Java, C-like, shell, SQL,
/// JSON, YAML, diff). A small tokenizer, not a parser: good enough to read, never fails.
enum SyntaxHighlighter {
    enum Token: Equatable { case plain, comment, string, number, keyword, type, function, attribute, added, removed }

    struct Language {
        var keywords: Set<String>
        var lineComment: [String] = ["//"]
        var blockComment: (String, String)? = ("/*", "*/")
        var quotes: [Character] = ["\"", "'"]
        /// Backtick strings (Go raw strings, JS templates).
        var backtick = false
        var caseInsensitive = false
    }

    static func language(_ name: String?) -> Language? {
        switch name?.lowercased() ?? "" {
        case "swift":
            return Language(keywords: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "import",
                                       "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "await", "async",
                                       "self", "Self", "nil", "true", "false", "static", "private", "public", "internal", "fileprivate", "init", "deinit",
                                       "where", "some", "any", "inout", "typealias", "associatedtype", "actor", "final", "override", "mutating", "do", "catch",
                                       "defer", "repeat", "is", "as", "weak", "lazy", "open", "nonisolated"], quotes: ["\""])
        case "go", "golang":
            return Language(keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range",
                                       "return", "switch", "case", "default", "break", "continue", "go", "defer", "select", "nil", "true", "false", "fallthrough",
                                       "goto", "string", "int", "int64", "bool", "error", "byte", "float64", "any"], quotes: ["\"", "'"], backtick: true)
        case "ts", "tsx", "typescript", "js", "jsx", "javascript", "mjs":
            return Language(keywords: ["function", "const", "let", "var", "if", "else", "return", "for", "while", "of", "in", "class", "extends", "implements",
                                       "interface", "type", "import", "export", "from", "default", "async", "await", "new", "this", "null", "undefined",
                                       "true", "false", "try", "catch", "finally", "throw", "switch", "case", "break", "continue", "typeof", "instanceof",
                                       "public", "private", "protected", "readonly", "enum", "as", "void", "yield", "static"], backtick: true)
        case "py", "python":
            return Language(keywords: ["def", "class", "if", "elif", "else", "return", "for", "while", "in", "not", "and", "or", "import", "from", "as", "with",
                                       "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "None", "True", "False", "self",
                                       "async", "await", "global", "nonlocal", "is", "del", "assert"], lineComment: ["#"], blockComment: nil)
        case "rust", "rs":
            return Language(keywords: ["fn", "let", "mut", "if", "else", "match", "return", "struct", "enum", "impl", "trait", "pub", "use", "mod", "for", "in",
                                       "while", "loop", "break", "continue", "self", "Self", "true", "false", "as", "where", "async", "await", "move", "ref",
                                       "const", "static", "type", "crate", "super", "dyn", "unsafe"], quotes: ["\""])
        case "kotlin", "kt", "java", "c", "cpp", "c++", "cs", "csharp", "scala", "dart":
            return Language(keywords: ["fun", "val", "var", "class", "interface", "object", "if", "else", "when", "return", "for", "while", "in", "is", "as",
                                       "import", "package", "public", "private", "protected", "internal", "static", "final", "void", "int", "long", "boolean",
                                       "new", "this", "super", "null", "true", "false", "try", "catch", "finally", "throw", "throws", "extends", "implements",
                                       "override", "abstract", "data", "suspend", "const", "struct", "enum", "switch", "case", "default", "break", "continue",
                                       "namespace", "using", "auto", "char", "double", "float", "string"])
        case "sh", "bash", "zsh", "shell", "console":
            return Language(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export",
                                       "local", "echo", "cd", "set", "unset", "exit", "source", "sudo"], lineComment: ["#"], blockComment: nil)
        case "sql":
            return Language(keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table",
                                       "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "limit", "as", "with", "recursive",
                                       "union", "all", "distinct", "having", "null", "is", "in", "exists", "primary", "key", "count", "sum", "case", "when",
                                       "then", "else", "end", "desc", "asc"], lineComment: ["--"], quotes: ["'"], caseInsensitive: true)
        case "json":
            return Language(keywords: ["true", "false", "null"], lineComment: [], blockComment: nil, quotes: ["\""])
        case "yaml", "yml", "toml", "hcl", "tf", "terraform":
            return Language(keywords: ["true", "false", "null", "yes", "no", "resource", "variable", "module", "output", "provider", "locals", "data"],
                            lineComment: ["#"], blockComment: nil)
        default:
            return nil
        }
    }

    /// The code as coloured text; plain monospaced text for unknown languages.
    static func highlight(_ code: String, language name: String?, scheme: ColorScheme) -> AttributedString {
        let lowered = name?.lowercased() ?? ""
        if lowered == "diff" || lowered == "patch" { return diff(code, scheme: scheme) }
        guard let language = language(name) else { return AttributedString(code) }
        var result = AttributedString()
        for (text, token) in tokens(code, language: language, yaml: ["yaml", "yml"].contains(lowered)) {
            var piece = AttributedString(text)
            if let color = color(token, scheme: scheme) { piece.foregroundColor = color }
            if token == .keyword { piece.font = .callout.monospaced().weight(.semibold) }
            result += piece
        }
        return result
    }

    /// Splits code into coloured runs.
    static func tokens(_ code: String, language: Language, yaml: Bool = false) -> [(String, Token)] {
        let characters = Array(code)
        var runs: [(String, Token)] = []
        var plain = ""
        func flush() { if !plain.isEmpty { runs.append((plain, .plain)); plain = "" } }
        func starts(_ text: String, at index: Int) -> Bool {
            let needle = Array(text)
            return !needle.isEmpty && index + needle.count <= characters.count && Array(characters[index..<index + needle.count]) == needle
        }
        var i = 0
        while i < characters.count {
            let c = characters[i]
            // Comments.
            if language.lineComment.contains(where: { starts($0, at: i) }) {
                flush()
                var j = i
                while j < characters.count, characters[j] != "\n" { j += 1 }
                runs.append((String(characters[i..<j]), .comment)); i = j; continue
            }
            if let (open, close) = language.blockComment, starts(open, at: i) {
                flush()
                var j = i + open.count
                while j < characters.count, !starts(close, at: j) { j += 1 }
                j = min(characters.count, j + close.count)
                runs.append((String(characters[i..<j]), .comment)); i = j; continue
            }
            // Strings.
            if language.quotes.contains(c) || (language.backtick && c == "`") {
                flush()
                var j = i + 1
                while j < characters.count, characters[j] != c {
                    if characters[j] == "\\" { j += 2; continue }
                    // Only template and raw strings span lines.
                    if c != "`", characters[j] == "\n" { break }
                    j += 1
                }
                j = min(characters.count, j + 1)
                runs.append((String(characters[i..<j]), .string)); i = j; continue
            }
            // Attributes and decorators: @MainActor, @app.route.
            if c == "@", i + 1 < characters.count, characters[i + 1].isLetter {
                flush()
                var j = i + 1
                while j < characters.count, characters[j].isLetter || characters[j].isNumber || characters[j] == "_" || characters[j] == "." { j += 1 }
                runs.append((String(characters[i..<j]), .attribute)); i = j; continue
            }
            // Numbers.
            if c.isNumber, i == 0 || !(characters[i - 1].isLetter || characters[i - 1] == "_") {
                flush()
                var j = i
                while j < characters.count, characters[j].isNumber || characters[j] == "." || characters[j] == "_" || characters[j] == "x" || characters[j].isHexDigit { j += 1 }
                runs.append((String(characters[i..<j]), .number)); i = j; continue
            }
            // Words: keywords, types, calls; YAML keys.
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < characters.count, characters[j].isLetter || characters[j].isNumber || characters[j] == "_" || characters[j] == "$" { j += 1 }
                let word = String(characters[i..<j])
                var k = j
                while k < characters.count, characters[k] == " " { k += 1 }
                let token: Token
                if language.keywords.contains(language.caseInsensitive ? word.lowercased() : word) {
                    token = .keyword
                } else if yaml, k < characters.count, characters[k] == ":" {
                    token = .type
                } else if k < characters.count, characters[k] == "(" {
                    token = .function
                } else if word.first?.isUppercase == true, word.count > 1 {
                    token = .type
                } else {
                    plain += word; i = j; continue
                }
                flush()
                runs.append((word, token)); i = j; continue
            }
            plain.append(c)
            i += 1
        }
        flush()
        return runs
    }

    private static func diff(_ code: String, scheme: ColorScheme) -> AttributedString {
        var result = AttributedString()
        for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((index > 0 ? "\n" : "") + line)
            if line.hasPrefix("+"), !line.hasPrefix("+++") { piece.foregroundColor = color(.added, scheme: scheme) }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { piece.foregroundColor = color(.removed, scheme: scheme) }
            else if line.hasPrefix("@@") { piece.foregroundColor = color(.keyword, scheme: scheme) }
            result += piece
        }
        return result
    }

    /// Xcode-like colours, tuned for light and dark.
    static func color(_ token: Token, scheme: ColorScheme) -> Color? {
        let dark = scheme == .dark
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
        switch token {
        case .plain: return nil
        case .comment: return dark ? rgb(127, 140, 152) : rgb(93, 108, 121)
        case .string: return dark ? rgb(252, 106, 93) : rgb(196, 26, 22)
        case .number: return dark ? rgb(208, 191, 105) : rgb(28, 0, 207)
        case .keyword: return dark ? rgb(252, 95, 163) : rgb(155, 35, 147)
        case .type: return dark ? rgb(93, 216, 255) : rgb(11, 79, 121)
        case .function: return dark ? rgb(103, 183, 164) : rgb(50, 109, 116)
        case .attribute: return dark ? rgb(253, 143, 63) : rgb(100, 56, 32)
        case .added: return dark ? rgb(103, 214, 120) : rgb(30, 130, 50)
        case .removed: return dark ? rgb(255, 120, 110) : rgb(190, 40, 40)
        }
    }
}
