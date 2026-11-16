import Foundation

/// HTTP calls a repository makes to other services: Go `net/http` requests, HTTP clients and
/// resty; `fetch`, axios (and its instances), Angular's `HttpClient`, ky and got; Python
/// `requests` and `httpx` (and their sessions and clients). The URL expression is read into
/// parts (see `URLPart`): a path becomes `calls_endpoint → endpoint:<METHOD> <path>`, the same
/// id a server route gets, so a call in one repository meets the route another one defines; a
/// base URL from an environment variable or a literal host becomes `calls_host → host:<name>`.
/// Edges start at the function making the call (the file outside any). Tests are skipped.
struct OutboundCallExtractor: CodeExtractor {
    let name = "calls"
    var sharedKinds: [String] { ["endpoint", "host"] }

    struct Call: Equatable {
        var method: String
        var url: [URLPart]
        var line: Int
    }

    func accepts(path: String, language: String) -> Bool {
        ["go", "typescript", "javascript", "python"].contains(language) && !SourceScan.isTest(path)
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        let calls: [Call] = switch file.language {
        case "go": GoCalls.find(file)
        case "python": PythonCalls.find(file)
        default: ScriptCalls.find(file)
        }
        var result = Extraction()
        var hosts = Set<String>()
        for call in calls {
            let target = URLPart.target(call.url)
            let caller = file.symbol(at: call.line) ?? file.fileID
            if let path = target.path {
                let method = EndpointExtractor.methods.contains(call.method) ? call.method : "ANY"
                result.edges.append(KnowledgeEdge(src: caller, dst: EndpointExtractor.id(method: method, path: path), kind: "calls_endpoint"))
            }
            if let host = target.host {
                let id = Self.hostID(host.name)
                if hosts.insert(id).inserted {
                    result.nodes.append(KnowledgeNode(id: id, kind: "host", name: host.name, qualified: host.name,
                                                      signature: host.fromEnvironment ? "Base URL from the environment variable \(host.name)" : "Host \(host.name)",
                                                      source: "code"))
                }
                result.edges.append(KnowledgeEdge(src: caller, dst: id, kind: "calls_host"))
            }
        }
        return result
    }

    static func hostID(_ name: String) -> String { "host:" + name }

    /// `http.MethodPost`, `"POST"`, `fiber.MethodPost` or a constant → "POST"; "ANY" otherwise.
    static func method(_ argument: String, in file: ExtractionInput) -> String {
        if let value = file.evaluate(argument)?.uppercased(), EndpointExtractor.methods.contains(value) { return value }
        if let name = SourceScan.matches(#"Method(\w+)$"#, in: argument).first?[1].uppercased(), EndpointExtractor.methods.contains(name) { return name }
        return "ANY"
    }

    /// The method a JS/Python options object or keyword names (`{ method: 'POST' }`, `method="POST"`).
    static func method(inOptions text: String, default fallback: String) -> String {
        SourceScan.matches(#"\bmethod\s*[:=]\s*['"`](\w+)['"`]"#, in: text).first.map { $0[1].uppercased() } ?? fallback
    }
}

/// A piece of a URL expression: known text, an environment variable (a base URL set per
/// deployment) or an expression that can't be read statically.
enum URLPart: Equatable {
    case text(String)
    case env(String)
    case unknown(String)

    /// Where the parts point: a host (a variable or a host name) and a normalized path (unknown
    /// pieces as `{}`), either possibly missing. A path needs a literal segment.
    static func target(_ raw: [URLPart]) -> (host: (name: String, fromEnvironment: Bool)?, path: String?) {
        var parts: [URLPart] = []
        for part in raw {
            if case .text(let text) = part {
                if text.isEmpty { continue }
                if case .text(let previous) = parts.last { parts[parts.count - 1] = .text(previous + text); continue }
            }
            parts.append(part)
        }
        guard let first = parts.first else { return (nil, nil) }
        var host: (name: String, fromEnvironment: Bool)?
        // "https://host/…", or a scheme read from somewhere (scheme + "://" + host + ":" + port).
        if let index = parts.prefix(2).firstIndex(where: { $0.text?.contains("://") == true }), index == 0 || first.text == nil,
           let text = parts[index].text {
            let rest = text[text.range(of: "://")!.upperBound...]
            let authority = rest.prefix { !"/?#".contains($0) }
            var remaining = Array(parts[(index + 1)...])
            if authority.count < rest.count || remaining.isEmpty {
                host = hostName(String(authority)).map { ($0, false) }
                remaining.insert(.text(String(rest.dropFirst(authority.count))), at: 0)
            } else {
                // The authority goes on past this literal: "https://" + host, or "https://host:" + port.
                if authority.isEmpty, case .env(let name) = remaining.first { host = (name, true) }
                if authority.contains(":") { host = hostName(String(authority)).map { ($0, false) } }
                while let part = remaining.first {
                    if let text = part.text, let start = text.firstIndex(where: { "/?#".contains($0) }) {
                        remaining[0] = .text(String(text[start...]))
                        break
                    }
                    remaining.removeFirst()
                }
            }
            parts = remaining
        } else {
            switch first {
            case .env(let name):
                host = (name, true)
                parts.removeFirst()
            case .unknown:
                parts.removeFirst()
            case .text:
                break
            }
        }
        var path = ""
        for part in parts {
            switch part {
            case .text(let text): path += text
            case .env, .unknown: path += "{}"
            }
        }
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<end]) }
        guard path.hasPrefix("/") else { return (host, nil) }
        let normalized = EndpointExtractor.normalize(path)
        guard normalized.split(separator: "/").contains(where: { !$0.contains("{}") && $0 != "*" }) else { return (host, nil) }
        return (host, normalized)
    }

    var text: String? {
        if case .text(let text) = self { text } else { nil }
    }

    /// "user@API.acme.test:8443" → "api.acme.test"; nil for a partial name ("api-" + region).
    private static func hostName(_ authority: String) -> String? {
        var name = String(authority.split(separator: "@").last ?? "").lowercased()
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        return name.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil ? name : nil
    }
}

extension ExtractionInput {
    /// Reads a URL expression at `offset` into parts: literals, `+`, Go `fmt.Sprintf`, template
    /// literals and f-strings (their expressions read too), `url.JoinPath`/`path.Join`/`urljoin`,
    /// `url.Parse`/`new URL`, environment reads, constants, a variable assigned earlier in the same
    /// function, and Go struct fields tagged with an environment variable.
    func urlParts(_ raw: String, at offset: Int, depth: Int = 0) -> [URLPart] {
        var expression = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".String()", ".toString()", ".href", "!"] where expression.hasSuffix(suffix) { expression.removeLast(suffix.count) }
        guard !expression.isEmpty, depth < 5 else { return [.unknown(expression)] }
        // A default after the value: `process.env.X || "http://localhost"`.
        for separator in ["||", "??", " or "] {
            let sides = SourceScan.splitTopLevel(expression.replacingOccurrences(of: separator, with: "\u{1}"), separator: "\u{1}")
            if sides.count > 1 { return urlParts(sides[0], at: offset, depth: depth + 1) }
        }
        let terms = SourceScan.splitTopLevel(expression, separator: "+")
        if terms.count > 1 { return terms.flatMap { urlParts($0, at: offset, depth: depth + 1) } }
        if let variable = Self.environmentVariable(expression) { return [.env(variable)] }
        if let pieces = SourceScan.templatePieces(expression) {
            return pieces.flatMap { $0.isExpression ? urlParts($0.text, at: offset, depth: depth + 1) : [URLPart.text($0.text)] }
        }
        if let literal = SourceScan.literal(expression) { return [.text(literal)] }
        if let call = SourceScan.call(expression) {
            switch call.callee {
            case "fmt.Sprintf", "fmt.Sprint":
                guard let format = call.arguments.first.flatMap(SourceScan.literal) else { break }
                if call.callee == "fmt.Sprint" { return call.arguments.flatMap { urlParts($0, at: offset, depth: depth + 1) } }
                var parts: [URLPart] = []
                var values = call.arguments.dropFirst().makeIterator()
                var last = format.startIndex
                for verb in format.ranges(of: #/%[-+# 0-9.]*[a-zA-Z]/#) {
                    parts.append(.text(String(format[last..<verb.lowerBound])))
                    parts += values.next().map { urlParts($0, at: offset, depth: depth + 1) } ?? [.unknown("")]
                    last = verb.upperBound
                }
                return parts + [.text(String(format[last...]))]
            case "url.JoinPath", "path.Join", "urljoin", "urllib.parse.urljoin", "posixpath.join":
                var parts: [URLPart] = []
                for (index, argument) in call.arguments.enumerated() {
                    if index > 0 { parts.append(.text("/")) }
                    parts += urlParts(argument, at: offset, depth: depth + 1)
                }
                return parts
            case "url.Parse", "url.ParseRequestURI", "new URL":
                if call.callee == "new URL", call.arguments.count == 2 {
                    return urlParts(call.arguments[1], at: offset, depth: depth + 1) + urlParts(call.arguments[0], at: offset, depth: depth + 1)
                }
                if let first = call.arguments.first { return urlParts(first, at: offset, depth: depth + 1) }
            default:
                break
            }
        }
        if expression.range(of: #"^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$"#, options: .regularExpression) != nil {
            if !expression.contains("."), let value = assignment(of: expression, before: offset) {
                return urlParts(value, at: offset, depth: depth + 1)
            }
            if let value = evaluate(expression) { return [.text(value)] }
            if language == "go", let field = expression.split(separator: ".").last, let variable = context.goEnvironmentFields()[String(field)] {
                return [.env(variable)]
            }
        }
        return [.unknown(expression)]
    }

    /// `os.Getenv("X")`, `process.env.X`, `os.environ["X"]`, `os.getenv("X")`… → "X".
    static func environmentVariable(_ expression: String) -> String? {
        let patterns = [#"^os\.(?:Getenv|LookupEnv)\("([A-Za-z_][A-Za-z0-9_]*)"\)$"#, #"^process\.env\.([A-Za-z_][A-Za-z0-9_]*)$"#,
                        #"^process\.env\[["'`]([A-Za-z_][A-Za-z0-9_]*)["'`]\]$"#, #"^import\.meta\.env\.([A-Za-z_][A-Za-z0-9_]*)$"#,
                        #"^os\.(?:environ\.get|getenv)\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["'].*\)$"#, #"^os\.environ\[["']([A-Za-z_][A-Za-z0-9_]*)["']\]$"#]
        for pattern in patterns {
            if let name = SourceScan.matches(pattern, in: expression).first?[1] { return name }
        }
        return nil
    }

    /// The expression last assigned to a variable before `offset`: in the same function first, then
    /// anywhere earlier in the file (a module-level `const BASE = process.env.X`). `u := …`,
    /// `u, err := url.Parse(…)`, `const u: string = …`, `u = …`.
    func assignment(of name: String, before offset: Int) -> String? {
        let pattern = SourceScan.regex(#"(?:^|[^\w.$])"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*(?:,\s*\w+\s*)?(?::\s*[\w.<>\[\]| ]+)?\s*:?=(?![=>])\s*"#)
        let function = function(at: line(at: offset)).map { self.offset(ofLine: $0.line) }
        for start in [function, 0].compactMap({ $0 }) where offset > start {
            let range = NSRange(location: start, length: offset - start)
            guard let match = pattern.matches(in: text, range: range).last else { continue }
            let value = SourceScan.expression(in: string, from: match.range.location + match.range.length)
            if !value.isEmpty { return value }
        }
        return nil
    }
}

extension SourceScan {
    /// A template literal or f-string as text and embedded expressions: `${base}/users/${id}` →
    /// [base, "/users/", id]. Nil for anything else.
    static func templatePieces(_ term: String) -> [(text: String, isExpression: Bool)]? {
        var body = Substring(term)
        var python = false
        if let first = body.first, "fF".contains(first) { python = true; body = body.dropFirst() }
        if let first = body.first, "rR".contains(first), python || body.dropFirst().first.map({ "fF".contains($0) }) == true {
            body = body.dropFirst()
            if !python, let next = body.first, "fF".contains(next) { python = true; body = body.dropFirst() }
        }
        guard body.count >= 2, let quote = body.first, body.last == quote, python ? "\"'".contains(quote) : quote == "`" else { return nil }
        let inner = Array(body.dropFirst().dropLast())
        var pieces: [(String, Bool)] = []
        var text = ""
        var index = 0
        while index < inner.count {
            let opens = python ? inner[index] == "{" : inner[index] == "$" && index + 1 < inner.count && inner[index + 1] == "{"
            if python, inner[index] == "{", index + 1 < inner.count, inner[index + 1] == "{" { text.append("{"); index += 2; continue }
            guard opens else { text.append(inner[index]); index += 1; continue }
            var depth = 0
            var end = index + (python ? 0 : 1)
            repeat {
                if inner[end] == "{" { depth += 1 } else if inner[end] == "}" { depth -= 1 }
                end += 1
            } while end < inner.count && depth > 0
            guard depth == 0 else { return nil }
            pieces.append((text, false))
            text = ""
            var expression = String(inner[(index + (python ? 1 : 2))..<(end - 1)])
            // f"{value!r:>10}": the conversion and format spec aren't part of the expression.
            if python, let cut = expression.firstIndex(where: { $0 == "!" || $0 == ":" }) { expression = String(expression[..<cut]) }
            pieces.append((expression, true))
            index = end
        }
        pieces.append((text, false))
        return pieces.contains(where: \.1) ? pieces : nil
    }

    /// A call expression filling the whole term: `fmt.Sprintf("x", a)` → ("fmt.Sprintf", ["\"x\"", "a"]),
    /// `new URL(p, base)` → ("new URL", …).
    static func call(_ term: String) -> (callee: String, arguments: [String])? {
        guard let match = matches(#"^(new\s+)?([A-Za-z_$][\w$.]*)\s*\("#, in: term).first else { return nil }
        let units = Array(term.utf16)
        let open = (match[0] as NSString).length - 1
        guard let arguments = arguments(units, at: open, limit: units.count), arguments.end == units.count else { return nil }
        let string = term as NSString
        return ((match[1].isEmpty ? "" : "new ") + match[2], arguments.ranges.map { string.substring(with: $0) })
    }

    /// The expression starting at `start`: up to the end of the line (or a `;`) outside brackets
    /// and strings, so a call spread over several lines is read whole.
    static func expression(in string: NSString, from start: Int) -> String {
        var depth = 0
        var quote: unichar?
        var escaped = false
        var index = start
        while index < string.length {
            let unit = string.character(at: index)
            if let open = quote {
                if escaped { escaped = false } else if unit == 92 && open != 96 { escaped = true } else if unit == open { quote = nil }
            } else {
                switch unit {
                case 34, 39, 96: quote = unit
                case 40, 91, 123: depth += 1
                case 41, 93, 125: if depth == 0 { return string.substring(with: NSRange(location: start, length: index - start)).trimmingCharacters(in: .whitespaces) }; depth -= 1
                case 10 where depth == 0, 59 where depth == 0: return string.substring(with: NSRange(location: start, length: index - start)).trimmingCharacters(in: .whitespaces)
                default: break
                }
            }
            index += 1
        }
        return string.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `key: value` entries of an object literal (`{ baseURL: x, method: 'GET', url }`).
    static func objectEntries(_ text: String) -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return [:] }
        var entries: [String: String] = [:]
        for item in splitTopLevel(String(trimmed.dropFirst().dropLast()), separator: ",") {
            let sides = splitTopLevel(item, separator: ":")
            let key = sides[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            guard !key.isEmpty else { continue }
            entries[key] = sides.count > 1 ? sides.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines) : key
        }
        return entries
    }

    /// A Python keyword argument's value (`base_url="…"` → `"…"`).
    static func keyword(_ name: String, in arguments: [String]) -> String? {
        arguments.first { $0.range(of: "^" + name + #"\s*="#, options: .regularExpression) != nil }
            .map { String($0[$0.index(after: $0.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Go

enum GoCalls {
    static func find(_ file: ExtractionInput) -> [OutboundCallExtractor.Call] {
        guard file.text.contains("http.") || file.text.contains("R()") || file.text.contains("lient") else { return [] }
        var calls: [OutboundCallExtractor.Call] = []
        for match in file.matches(SourceScan.regex(#"\bhttp\.(NewRequestWithContext|NewRequest|Get|Post|PostForm|Head)\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1) else { continue }
            let texts = arguments.ranges.map { file.text($0) }
            let name = file.text(match.range(at: 1))
            let method: String, url: String
            switch name {
            case "NewRequestWithContext":
                guard texts.count >= 3 else { continue }
                (method, url) = (OutboundCallExtractor.method(texts[1], in: file), texts[2])
            case "NewRequest":
                guard texts.count >= 2 else { continue }
                (method, url) = (OutboundCallExtractor.method(texts[0], in: file), texts[1])
            default:
                guard let first = texts.first else { continue }
                (method, url) = (name == "PostForm" ? "POST" : name.uppercased(), first)
            }
            calls.append(.init(method: method, url: file.urlParts(url, at: match.range.location), line: file.line(at: match.range.location)))
        }
        // An HTTP client (`c.httpClient.Get(url)`) or resty (`c.R().SetBody(b).Post(url)`).
        for match in file.matches(SourceScan.regex(#"\.(Get|Post|Put|Patch|Delete|Head|Options)\s*\("#)) {
            let receiver = file.receiver(before: match.range.location)
            let last = receiver.split(separator: ".").last.map { String($0.prefix { $0 != "(" }) } ?? ""
            guard receiver.range(of: #"(^|\.)R\(\)"#, options: .regularExpression) != nil || (last.lowercased().hasSuffix("client") && last != "http"),
                  let arguments = file.arguments(at: match.range.location + match.range.length - 1), let first = arguments.ranges.first else { continue }
            calls.append(.init(method: file.text(match.range(at: 1)).uppercased(), url: file.urlParts(file.text(first), at: match.range.location),
                               line: file.line(at: match.range.location)))
        }
        return calls
    }
}

// MARK: - TypeScript and JavaScript

enum ScriptCalls {
    private static let verbs = "get|post|put|patch|delete|head|options"

    static func find(_ file: ExtractionInput) -> [OutboundCallExtractor.Call] {
        guard ["fetch", "axios", "http", "ky", "got"].contains(where: file.text.contains) else { return [] }
        var calls: [OutboundCallExtractor.Call] = []
        func add(_ method: String, _ url: String, _ offset: Int, base: [URLPart] = []) {
            var parts = file.urlParts(url, at: offset)
            if case .text(let text) = parts.first, text.contains("://") {} else { parts = base + parts }
            calls.append(.init(method: method.uppercased(), url: parts, line: file.line(at: offset)))
        }
        func arguments(_ match: NSTextCheckingResult) -> [String]? {
            file.arguments(at: match.range.location + match.range.length - 1).map { $0.ranges.map { file.text($0) } }
        }
        for match in file.matches(SourceScan.regex(#"(?<![\w$.])(?:window\.|globalThis\.)?fetch\s*\("#)) {
            guard let texts = arguments(match), let url = texts.first else { continue }
            add(OutboundCallExtractor.method(inOptions: texts.count > 1 ? texts[1] : "", default: "GET"), url, match.range.location)
        }
        // axios.get(url), ky.post(url), got.put(url), this.http.get<T>(url).
        for match in file.matches(SourceScan.regex(#"(?<![\w$.])(?:axios|ky|got|this\.http|this\.httpClient)\.(\#(verbs)|request)\s*(?:<[^<>()]*>)?\s*\("#)) {
            guard let texts = arguments(match), let first = texts.first else { continue }
            let verb = file.text(match.range(at: 1))
            if verb != "request" { add(verb, first, match.range.location); continue }
            let options = SourceScan.objectEntries(first)
            if let url = options["url"] { add(OutboundCallExtractor.method(inOptions: first, default: "GET"), url, match.range.location) }
            else if texts.count > 1 { add(file.evaluate(first) ?? "ANY", texts[1], match.range.location) }
        }
        for match in file.matches(SourceScan.regex(#"(?<![\w$.])axios\s*\(\s*\{"#)) {
            guard let texts = arguments(match), let first = texts.first, let url = SourceScan.objectEntries(first)["url"] else { continue }
            add(OutboundCallExtractor.method(inOptions: first, default: "GET"), url, match.range.location)
        }
        // const api = axios.create({ baseURL: process.env.BILLING_API_URL }); api.get('/invoices').
        for match in file.matches(SourceScan.regex(#"\b([A-Za-z_$][\w$]*)\s*=\s*(?:axios|ky)\.(?:create|extend)\s*\("#)) {
            guard let texts = arguments(match) else { continue }
            let options = texts.first.map(SourceScan.objectEntries) ?? [:]
            let base = (options["baseURL"] ?? options["prefixUrl"]).map { file.urlParts($0, at: match.range.location) } ?? []
            let instance = file.text(match.range(at: 1))
            for call in file.matches(SourceScan.regex(#"(?<![\w$.])"# + NSRegularExpression.escapedPattern(for: instance) + #"\.(\#(verbs))\s*(?:<[^<>()]*>)?\s*\("#)) {
                guard let texts = arguments(call), let url = texts.first else { continue }
                add(file.text(call.range(at: 1)), url, call.range.location, base: base)
            }
        }
        return calls
    }
}

// MARK: - Python

enum PythonCalls {
    private static let verbs = "get|post|put|patch|delete|head|options"

    static func find(_ file: ExtractionInput) -> [OutboundCallExtractor.Call] {
        guard file.text.contains("requests") || file.text.contains("httpx") else { return [] }
        var calls: [OutboundCallExtractor.Call] = []
        func arguments(_ match: NSTextCheckingResult) -> (texts: [String], end: Int)? {
            file.arguments(at: match.range.location + match.range.length - 1).map { ($0.ranges.map { file.text($0) }, $0.end) }
        }
        func add(_ match: NSTextCheckingResult, verb: String, _ texts: [String], base: [URLPart] = []) {
            var method = verb.uppercased()
            var positional = texts.filter { $0.range(of: #"^\w+\s*="#, options: .regularExpression) == nil }
            if verb == "request" {
                guard !positional.isEmpty else { return }
                method = file.evaluate(positional.removeFirst())?.uppercased() ?? "ANY"
            }
            guard let url = SourceScan.keyword("url", in: texts) ?? positional.first else { return }
            var parts = file.urlParts(url, at: match.range.location)
            if case .text(let text) = parts.first, text.contains("://") {} else { parts = base + parts }
            calls.append(.init(method: method, url: parts, line: file.line(at: match.range.location)))
        }
        for match in file.matches(SourceScan.regex(#"(?<![\w.])(?:requests|httpx)\.(\#(verbs)|request)\s*\("#)) {
            guard let texts = arguments(match)?.texts else { continue }
            add(match, verb: file.text(match.range(at: 1)), texts)
        }
        // Sessions and clients: `client = httpx.Client(base_url=…)`, `with requests.Session() as s:`.
        var clients: [String: [URLPart]] = [:]
        for match in file.matches(SourceScan.regex(#"(?:\b(\w+)\s*=\s*|\bwith\s+)(?:requests\.Session|httpx\.(?:Async)?Client)\s*\("#)) {
            guard let found = arguments(match) else { continue }
            let texts = found.texts
            let named = match.range(at: 1).location != NSNotFound ? file.text(match.range(at: 1))
                : SourceScan.matches(#"^\s*as\s+(\w+)"#, in: String(file.string.substring(from: found.end).prefix(40))).first?[1]
            guard let name = named else { continue }
            clients[name] = SourceScan.keyword("base_url", in: texts).map { file.urlParts($0, at: match.range.location) } ?? []
        }
        for (name, base) in clients {
            for match in file.matches(SourceScan.regex(#"(?<![\w.])"# + NSRegularExpression.escapedPattern(for: name) + #"\.(\#(verbs)|request)\s*\("#)) {
                guard let texts = arguments(match)?.texts else { continue }
                add(match, verb: file.text(match.range(at: 1)), texts, base: base)
            }
        }
        return calls
    }
}
