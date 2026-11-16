import Foundation

// What the extractors add to the knowledge graph, beyond files and symbols. Ids are stable across
// re-indexes; the ones without a repository in them are shared, so one route served by a
// repository and called from another is a single node.
//
//   service:<repo id>:<name>     something the repository deploys or runs: a Dockerfile, Helm
//                                chart, Kubernetes workload, compose service, package.json start
//                                script or Go command. Signature "Defined in <files>".
//   endpoint:<METHOD> <path>     an HTTP route, from code or an OpenAPI document. Parameters are
//                                written {}, the method ANY when it isn't known. Shared. Its
//                                name keeps the path as written; its language is the framework.
//                                Signature "GET /users/{} → handlers.GetUser". A route only
//                                called, never defined, is just "GET /users/{}".
//   host:<name>                  where a call goes when no route says: the environment variable
//                                holding the base URL (BILLING_API_URL) or a literal host name
//                                (billing-api.default.svc.cluster.local). Shared.
//   grpc:<pkg>.<Service>         a gRPC service in a .proto (rpc_service), "grpc:<pkg>.<Service>/<Method>"
//                                its rpcs (rpc), proto:<pkg>.<Message> its messages (message); no
//                                package, no "<pkg>.". Shared; path and line say where.
//
//   service  —defined_in→ file      repo     —deploys→ service     service —runs→ dir (or repo)
//   endpoint —defined_in→ file      endpoint —handled_by→ symbol    service —exposes→ endpoint
//   symbol   —calls_endpoint→ endpoint (or file, outside any function)
//   symbol   —calls_host→ host
//   rpc_service —defined_in→ file   rpc_service —contains→ rpc      rpc, message —defined_in→ file
//   symbol   —implements→ rpc_service     symbol —calls_rpc→ rpc_service   (resolved by ServiceLinks)
//
// Edges an extractor writes for a file carry the file's id as their `source`: re-indexing the
// file replaces exactly those, whatever their ends. Edges that need the whole repository (a
// handler's name resolved to a symbol, the folder a service runs) are kept as refs and made by
// `ExtractionLinks` once the repository is indexed, under the source "code-links". Shared nodes
// nothing points at any more are dropped there too. Then `ServiceLinks` looks across repositories
// (source "service-links"): host —about→ service, and calls_endpoint from a call no repository
// defines to the routes it likely reaches (weight below 1).

/// Finds one family of things in a file (services, endpoints, …): deterministic and local, no
/// model and no network, cheap enough to run on every changed file.
protocol CodeExtractor: Sendable {
    var name: String { get }
    /// Kinds of shared nodes it makes (no repository in their id): dropped once nothing links to them.
    var sharedKinds: [String] { get }
    /// A quick test on the path and language, so most files skip the extractor.
    func accepts(path: String, language: String) -> Bool
    func extract(_ file: ExtractionInput) -> Extraction
}

extension CodeExtractor {
    var sharedKinds: [String] { [] }
}

/// What extractors found in one file.
struct Extraction: Sendable {
    var nodes: [KnowledgeNode] = []
    var edges: [KnowledgeEdge] = []
    var refs: [KnowledgeRef] = []

    mutating func add(_ other: Extraction) {
        nodes += other.nodes
        edges += other.edges
        refs += other.refs
    }
}

enum CodeExtractors {
    /// Bumped when extractors find more: a repository without this meta key is parsed again once.
    static let version = "extract-v3"

    static let all: [any CodeExtractor] = [ServiceExtractor(), EndpointExtractor(), OpenAPIExtractor(), OutboundCallExtractor(), ProtobufExtractor()]

    /// Runs the extractors that accept the file, adding the time each took to `timings`. Every
    /// edge is filed under the file, so it goes when the file is indexed again.
    static func run(_ file: ExtractionInput, extractors: [any CodeExtractor] = all, timings: inout [String: Duration]) -> Extraction {
        var result = Extraction()
        let clock = ContinuousClock()
        for extractor in extractors where extractor.accepts(path: file.path, language: file.language) {
            var found = Extraction()
            timings[extractor.name, default: .zero] += clock.measure { found = extractor.extract(file) }
            result.add(found)
        }
        for index in result.edges.indices { result.edges[index].source = file.fileID }
        return result
    }
}

/// Caches shared by the files of one repository while it's indexed: the Go module and the string
/// constants of each Go package, read on demand.
final class ExtractionContext: @unchecked Sendable {
    let root: URL
    let goModule: String?
    private let lock = NSLock()
    private let goFiles: [String: [String]]
    private var goConstants: [String: [String: String]] = [:]

    init(root: URL, files: [String], goModule: String?) {
        self.root = root
        self.goModule = goModule
        var byDirectory: [String: [String]] = [:]
        for path in files where path.hasSuffix(".go") && !path.hasSuffix("_test.go") {
            byDirectory[(path as NSString).deletingLastPathComponent, default: []].append(path)
        }
        goFiles = byDirectory
    }

    /// The string constants (and package-level string variables) of the Go package in a directory:
    /// name → the expression it's set to.
    func goConstants(in directory: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let known = goConstants[directory] { return known }
        var constants: [String: String] = [:]
        for path in goFiles[directory] ?? [] {
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { continue }
            constants.merge(SourceScan.goConstants(text)) { first, _ in first }
        }
        goConstants[directory] = constants
        return constants
    }

    private var environmentFields: [String: String]?

    /// Go struct fields set from an environment variable anywhere in the repository
    /// (`BaseURL string `env:"BASE_URL"``): field name → variable. A name tagged with two
    /// different variables is left out. Read once, on demand.
    func goEnvironmentFields() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let known = environmentFields { return known }
        var found: [String: Set<String>] = [:]
        for path in goFiles.values.joined() {
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8),
                  text.contains("env:\"") || text.contains("envconfig:\"") else { continue }
            for match in SourceScan.matches(#"(?m)^\s*([A-Z]\w*)\s+[\w.*\[\]]+\s+`[^`\n]*\b(?:env|envconfig):"([A-Z][A-Z0-9_]*)[",]"#, in: text) {
                found[match[1], default: []].insert(match[2])
            }
        }
        let fields = found.compactMapValues { $0.count == 1 ? $0.first : nil }
        environmentFields = fields
        return fields
    }
}

/// One file as extractors see it: its text, what the parser found, and helpers to read call
/// sites (offsets are UTF-16, as `NSRegularExpression` reports them).
final class ExtractionInput {
    let root: String
    let repoID: String
    let path: String
    let language: String
    let text: String
    let parsed: ParsedFile
    let symbolIDs: [String]
    let files: [String]
    let context: ExtractionContext

    init(root: String, path: String, language: String, text: String, parsed: ParsedFile, symbolIDs: [String], files: [String], context: ExtractionContext) {
        self.root = root
        self.repoID = "repo:" + root
        self.path = path
        self.language = language
        self.text = text
        self.parsed = parsed
        self.symbolIDs = symbolIDs
        self.files = files
        self.context = context
    }

    var fileID: String { "file:" + root + "/" + path }
    func directoryID(_ path: String) -> String { "dir:" + root + "/" + path }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var fileName: String { (path as NSString).lastPathComponent }
    var repoName: String { (root as NSString).lastPathComponent }

    lazy var string: NSString = text as NSString
    lazy var units: [unichar] = Array(text.utf16)
    private lazy var lineStarts: [Int] = {
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == 10 { starts.append(index + 1) }
        return starts
    }()

    /// Test code, mocks and fixtures: what they register or call isn't the service's own.
    lazy var isTest: Bool = SourceScan.isTest(path)

    /// The 1-based line of a UTF-16 offset.
    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(low, 1)
    }

    /// The UTF-16 offset where a 1-based line starts.
    func offset(ofLine line: Int) -> Int {
        lineStarts[min(max(line, 1), lineStarts.count) - 1]
    }

    func text(_ range: NSRange) -> String {
        range.location == NSNotFound ? "" : string.substring(with: range)
    }

    func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(location: 0, length: string.length))
    }

    /// The innermost declaration around a line (the function registering a route, say).
    func symbol(at line: Int) -> String? {
        var best: Int?
        for (index, symbol) in parsed.symbols.enumerated() where symbol.line <= line && line <= max(symbol.endLine, symbol.line) {
            if let current = best, parsed.symbols[current].line > symbol.line { continue }
            best = index
        }
        return best.map { symbolIDs[$0] }
    }

    /// The innermost function or method around a line.
    func function(at line: Int) -> ParsedFile.Symbol? {
        parsed.symbols.filter { ["function", "method"].contains($0.kind) && $0.line <= line && line <= max($0.endLine, $0.line) }
            .max { $0.line < $1.line }
    }

    /// What a method is called on, read backwards from the "." before its name: `s.mux` in
    /// `s.mux.Get(`, `r.With(auth)` in `r.With(auth).Get(`.
    func receiver(before dot: Int) -> String {
        var index = dot - 1
        var depth = 0
        while index >= 0 {
            let unit = units[index]
            if unit == 41 || unit == 93 { depth += 1 }
            else if unit == 40 || unit == 91 { if depth == 0 { break }; depth -= 1 }
            else if depth == 0, !(SourceScan.isIdentifier(unit) || unit == 46) { break }
            index -= 1
        }
        return index + 1 < dot ? string.substring(with: NSRange(location: index + 1, length: dot - index - 1)) : ""
    }

    /// The text from the start of the line up to `offset`.
    func lineText(before offset: Int) -> String {
        let start = lineStarts[line(at: offset) - 1]
        return offset > start ? string.substring(with: NSRange(location: start, length: offset - start)) : ""
    }

    /// Calls chained after `offset`: `.Methods("GET").Name("x")` → [("Methods", …), ("Name", …)].
    func chain(after offset: Int) -> [(name: String, arguments: [NSRange], end: Int)] {
        var result: [(String, [NSRange], Int)] = []
        var index = offset
        while true {
            while index < units.count, SourceScan.isSpace(units[index]) { index += 1 }
            guard index < units.count, units[index] == 46 else { break }
            var end = index + 1
            while end < units.count, SourceScan.isIdentifier(units[end]) { end += 1 }
            let name = string.substring(with: NSRange(location: index + 1, length: end - index - 1))
            guard !name.isEmpty, end < units.count, units[end] == 40, let call = arguments(at: end) else { break }
            result.append((name, call.ranges, call.end))
            index = call.end
        }
        return result
    }

    /// The offset of the bracket closing the one at `open` (`(`, `[` or `{`).
    func closing(at open: Int) -> Int? {
        SourceScan.arguments(units, at: open, limit: 200_000).map { $0.end - 1 }
    }

    /// The first declaration starting on or within a few lines after `line` (what a decorator decorates).
    func symbol(after line: Int, within lines: Int = 12) -> (id: String, symbol: ParsedFile.Symbol)? {
        guard let index = parsed.symbols.indices.filter({ parsed.symbols[$0].line >= line && parsed.symbols[$0].line <= line + lines })
            .min(by: { parsed.symbols[$0].line < parsed.symbols[$1].line }) else { return nil }
        return (symbolIDs[index], parsed.symbols[index])
    }

    /// The arguments of the call whose "(" is at `open`, split at top-level commas and trimmed,
    /// and the offset just past its ")". Nil when it doesn't close within `limit` characters.
    func arguments(at open: Int, limit: Int = 6000) -> (ranges: [NSRange], end: Int)? {
        SourceScan.arguments(units, at: open, limit: limit)
    }

    // MARK: String expressions

    /// The value of a string expression: literals joined with `+`, template and format
    /// placeholders as `{}`, constants of the file (and, in Go, of its package or an imported
    /// one of the module). Unknown parts are left out; nil when nothing is known.
    func evaluate(_ expression: String) -> String? {
        evaluate(expression, goDirectory: directory, depth: 0)
    }

    private func evaluate(_ expression: String, goDirectory: String, depth: Int) -> String? {
        guard depth < 4 else { return nil }
        var value = ""
        var known = false
        for term in SourceScan.splitTopLevel(expression, separator: "+") {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if let literal = SourceScan.literal(term) {
                value += literal
                known = true
            } else if let format = SourceScan.formatCall(term) {
                value += format
                known = true
            } else if term.range(of: #"^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)?$"#, options: .regularExpression) != nil,
                      let constant = constant(term, goDirectory: goDirectory, depth: depth) {
                value += constant
                known = true
            }
        }
        return known ? value : nil
    }

    private func constant(_ name: String, goDirectory: String, depth: Int) -> String? {
        if language == "go" {
            let parts = name.split(separator: ".").map(String.init)
            if parts.count == 1, let expression = context.goConstants(in: goDirectory)[name] {
                return evaluate(expression, goDirectory: goDirectory, depth: depth + 1)
            }
            if parts.count == 2, let directory = goImports[parts[0]], let expression = context.goConstants(in: directory)[parts[1]] {
                return evaluate(expression, goDirectory: directory, depth: depth + 1)
            }
            return nil
        }
        return localConstants[name].flatMap { evaluate($0, goDirectory: goDirectory, depth: depth + 1) }
    }

    /// Go import aliases of packages inside the module → their directories.
    private lazy var goImports: [String: String] = {
        guard let module = context.goModule else { return [:] }
        var result: [String: String] = [:]
        for match in SourceScan.regex(#"(?m)^\s*(?:import\s+)?(?:([A-Za-z_]\w*)\s+)?"([^"\s]+)"\s*$"#).matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let importPath = text(match.range(at: 2))
            guard importPath == module || importPath.hasPrefix(module + "/") else { continue }
            let directory = String(importPath.dropFirst(module.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let alias = match.range(at: 1).location != NSNotFound ? text(match.range(at: 1)) : (importPath as NSString).lastPathComponent
            result[alias] = directory
        }
        return result
    }()

    /// `const X = "…"` (TS/JS), `X = "…"` (Python) and `let x = "…"` (Swift) in this file.
    private lazy var localConstants: [String: String] = {
        var result: [String: String] = [:]
        let pattern = #"(?m)^\s*(?:export\s+)?(?:(?:const|let|var|static\s+let|private\s+let|public\s+let)\s+)?([A-Za-z_$][\w$]*)\s*(?::\s*[\w.<>]+)?\s*=\s*((?:["'`]).*?["'`])\s*;?\s*$"#
        for match in SourceScan.regex(pattern).matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let name = text(match.range(at: 1))
            if result[name] == nil { result[name] = text(match.range(at: 2)) }
        }
        return result
    }()
}

/// Small, allocation-light readers of source text shared by the extractors.
enum SourceScan {
    private static let cache = RegexCache()

    /// A compiled regular expression, cached (extractors run on thousands of files).
    static func regex(_ pattern: String) -> NSRegularExpression { cache.regex(pattern) }

    /// The groups of every match of `pattern` in `text`.
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        let string = text as NSString
        return regex(pattern).matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) }
        }
    }

    /// A path relative to `directory` inside the repository ("" for its root), nil when it leaves it.
    static func join(_ directory: String, _ relative: String) -> String? {
        var parts = relative.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if parts.isEmpty { return nil } else { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    static func isTest(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let folders = lower.split(separator: "/").dropLast().map(String.init)
        if name.hasSuffix("_test.go") || name.hasSuffix("_mock.go") || name.hasPrefix("mock_") || name.contains(".test.") || name.contains(".spec.")
            || name.hasPrefix("test_") || name.hasSuffix("_test.py") || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") { return true }
        return folders.contains { ["__tests__", "tests", "test", "testdata", "mocks", "mock", "fixtures", "e2e", "__mocks__"].contains($0) }
    }

    /// The value of a string literal (Go, JS/TS, Python, Swift): quotes removed, simple escapes
    /// read, `${…}` and `\(…)` placeholders as `{}`. Nil when `term` isn't one literal.
    static func literal(_ term: String) -> String? {
        var body = Substring(term)
        if let first = body.first, "fFrRbB".contains(first), body.dropFirst().first.map({ "\"'".contains($0) }) == true { body = body.dropFirst() }
        guard body.count >= 2, let quote = body.first, "\"'`".contains(quote), body.last == quote else { return nil }
        var inner = String(body.dropFirst().dropLast())
        if quote != "`" {
            // A closing quote inside means it's several literals or an expression, not one.
            var escaped = false
            for character in inner {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == quote { return nil }
            }
            inner = inner.replacingOccurrences(of: "\\\(quote)", with: String(quote)).replacingOccurrences(of: "\\/", with: "/")
        }
        inner = inner.replacingOccurrences(of: #"\$\{[^}]*\}|\\\([^)]*\)"#, with: "{}", options: .regularExpression)
        return inner
    }

    /// `fmt.Sprintf("/users/%s", id)` and friends: the format with its verbs as `{}`.
    static func formatCall(_ term: String) -> String? {
        guard let open = term.firstIndex(of: "("), term.hasSuffix(")") else { return nil }
        let callee = term[..<open]
        guard ["fmt.Sprintf", "String.format", "format", "sprintf", "util.format"].contains(callee) else { return nil }
        let arguments = splitTopLevel(String(term[term.index(after: open)..<term.index(before: term.endIndex)]), separator: ",")
        guard let format = arguments.first.flatMap({ literal($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        return format.replacingOccurrences(of: #"%[-+# 0-9.]*[a-zA-Z]"#, with: "{}", options: .regularExpression)
    }

    /// Splits at a separator outside strings and brackets.
    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                current.append(character)
                if escaped { escaped = false } else if character == "\\" && open != "`" { escaped = true } else if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'", "`": quote = character; current.append(character)
            case "(", "[", "{": depth += 1; current.append(character)
            case ")", "]", "}": depth -= 1; current.append(character)
            case separator where depth == 0: parts.append(current); current = ""
            default: current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// See `ExtractionInput.arguments(at:limit:)`; also reads `[…]` and `{…}` (their items split at commas).
    static func arguments(_ units: [unichar], at open: Int, limit: Int) -> (ranges: [NSRange], end: Int)? {
        guard open < units.count, let closer: unichar = [40: 41, 91: 93, 123: 125][units[open]] else { return nil }
        var ranges: [NSRange] = []
        var depth = 0
        var start = open + 1
        var index = open + 1
        var quote: unichar?
        var escaped = false
        func add(_ end: Int) {
            var low = start, high = end
            while low < high, isSpace(units[low]) { low += 1 }
            while high > low, isSpace(units[high - 1]) { high -= 1 }
            if high > low { ranges.append(NSRange(location: low, length: high - low)) }
        }
        let end = min(units.count, open + limit)
        while index < end {
            let unit = units[index]
            if let open = quote {
                if escaped { escaped = false } else if unit == 92 && open != 96 { escaped = true } else if unit == open { quote = nil }
                index += 1
                continue
            }
            switch unit {
            case 34, 39, 96: quote = unit
            case 47 where index + 1 < end && units[index + 1] == 47:
                // A line comment inside the arguments; one before an argument isn't part of it.
                let leading = (start..<index).allSatisfy { isSpace(units[$0]) }
                while index < end, units[index] != 10 { index += 1 }
                if leading { start = index }
                continue
            case 40, 91, 123: depth += 1
            case 41, 93, 125:
                if depth == 0 {
                    guard unit == closer else { return nil }
                    add(index)
                    return (ranges, index + 1)
                }
                depth -= 1
            case 44 where depth == 0:
                add(index)
                start = index + 1
            default: break
            }
            index += 1
        }
        return nil
    }

    static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 }

    /// A letter, digit, `_` or `$` (ASCII: identifiers in route code are).
    static func isIdentifier(_ unit: unichar) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36
    }

    /// Top-level Go string constants and variables: name → expression.
    static func goConstants(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var inBlock = false
        var depth = 0
        let declaration = regex(#"^(?:const\s+|var\s+)?([A-Za-z_]\w*)(?:\s+string)?\s*=\s*(.+)$"#)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = withoutLineComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if depth == 0, line == "const (" || line == "var (" { inBlock = true; continue }
            if inBlock, line.hasPrefix(")") { inBlock = false; continue }
            if inBlock || (depth == 0 && (line.hasPrefix("const ") || line.hasPrefix("var "))) {
                let range = NSRange(location: 0, length: (line as NSString).length)
                if let match = declaration.firstMatch(in: line, range: range) {
                    let name = (line as NSString).substring(with: match.range(at: 1))
                    let expression = (line as NSString).substring(with: match.range(at: 2))
                    if expression.contains("\"") || expression.contains("`") || expression.range(of: #"^[A-Za-z_][\w.]*(\s*\+\s*[\w."` ]+)*$"#, options: .regularExpression) != nil {
                        if result[name] == nil { result[name] = expression }
                    }
                }
            }
            if !inBlock { depth += braceDelta(line) }
        }
        return result
    }

    /// The line without a `//` comment (one outside strings).
    static func withoutLineComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open != "`" { escaped = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if character == "/" && previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    /// Opening minus closing braces outside strings.
    static func braceDelta(_ line: String) -> Int {
        var delta = 0
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open != "`" { escaped = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
        }
        return delta
    }
}

/// Compiled regular expressions by pattern, shared across threads.
private final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let known = compiled[pattern] { return known }
        let regex = try! NSRegularExpression(pattern: pattern)
        compiled[pattern] = regex
        return regex
    }
}
