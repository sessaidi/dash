import Foundation

/// HTTP endpoints a repository serves, `endpoint:<METHOD> <path>`: path parameters (`:id`,
/// `{id}`, `<int:id>`, `[id]`, `(?P<id>…)`) are written `{}`, so the same route declared by a
/// server and called from elsewhere is one node. Found in route registrations: Go net/http (with
/// Go 1.22 method patterns), goji, gorilla/mux, chi, gin, echo, fiber and httprouter; Express,
/// Koa, Fastify, Hono, NestJS and Next.js; Flask, FastAPI and Django; Vapor. Prefixes from
/// groups, sub-routers and mounts in the same file are applied; string constants are read from
/// the file (in Go, its package or an imported one). Tests and mocks are skipped. Each endpoint
/// is `defined_in` its file and gets a ref to its handler (`handled_by`, resolved by name).
struct EndpointExtractor: CodeExtractor {
    let name = "endpoints"
    var sharedKinds: [String] { ["endpoint"] }

    struct Route: Equatable {
        var method: String
        var path: String
        var line: Int
        /// Candidate names for the handler, best first ("sym:…" when it's known exactly).
        var handler: [String] = []
        var framework: String
    }

    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE"]

    static func id(method: String, path: String) -> String { "endpoint:" + method + " " + path }

    func accepts(path: String, language: String) -> Bool {
        ["go", "typescript", "javascript", "python", "swift"].contains(language) && !SourceScan.isTest(path)
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        let routes: [Route] = switch file.language {
        case "go": GoRoutes.find(file)
        case "typescript", "javascript": ScriptRoutes.find(file)
        case "python": PythonRoutes.find(file)
        case "swift": VaporRoutes.find(file)
        default: []
        }
        return Self.extraction(routes, in: file)
    }

    /// Endpoint nodes, `defined_in` edges and handler refs for routes found in a file.
    static func extraction(_ routes: [Route], in file: ExtractionInput) -> Extraction {
        var result = Extraction()
        var seen = Set<String>()
        for route in routes {
            let method = methods.contains(route.method.uppercased()) ? route.method.uppercased() : "ANY"
            let path = normalize(route.path)
            let id = id(method: method, path: path)
            guard seen.insert(id).inserted else { continue }
            let handler = route.handler.first.map { $0.hasPrefix("sym:") ? String($0.split(separator: "#").last ?? "") : $0 } ?? ""
            result.nodes.append(KnowledgeNode(id: id, kind: "endpoint", name: method + " " + clean(route.path), qualified: method + " " + path,
                                              language: route.framework, signature: method + " " + path + (handler.isEmpty ? "" : " → " + handler),
                                              source: "code"))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            if !route.handler.isEmpty { result.refs.append(KnowledgeRef(src: id, kind: "handled_by", names: route.handler, line: route.line)) }
        }
        return result
    }

    // MARK: Paths

    /// The path as written, tidied: no scheme or host, one leading slash, no doubled or trailing
    /// slash, no query, no regular-expression anchors.
    static func clean(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = path.range(of: "://") {
            let rest = path[scheme.upperBound...]
            path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        if path.hasPrefix("^") { path.removeFirst() }
        if path.hasSuffix("$") { path.removeLast() }
        if !path.contains("(?"), let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<query]) }
        path = path.replacingOccurrences(of: #"/{2,}"#, with: "/", options: .regularExpression)
        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The path every framework's spelling of it maps to: parameters as `{}`, catch-alls as `*`.
    static func normalize(_ raw: String) -> String {
        let path = clean(raw).replacingOccurrences(of: #"\(\?P<\w+>[^)]*\)"#, with: "{}", options: .regularExpression)
        let segments = path.split(separator: "/").map { segment -> String in
            if segment.hasPrefix(":") || (segment.hasPrefix("[") && segment.hasSuffix("]")) { return "{}" }
            if segment.hasPrefix("*") { return "*" }
            return String(segment)
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "{}", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]*>"#, with: "{}", options: .regularExpression)
        }
        return "/" + segments.joined(separator: "/")
    }

    /// A prefix and a path joined with one slash.
    static func join(_ prefix: String, _ path: String) -> String {
        guard !prefix.isEmpty else { return path }
        let tail = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return tail.isEmpty ? head : head + "/" + tail
    }

    // MARK: Handlers

    /// Calls that wrap a handler rather than being it.
    static let wrappers: Set<String> = ["handle", "handlefunc", "handlerfunc", "handler", "normalize", "wrap", "chain", "with", "use", "then",
                                        "stripprefix", "timeouthandler", "timeout", "as_view", "bind", "asyncHandler".lowercased(), "catchasync"]

    /// Candidate handler names in a handler argument, best first: references before calls (a
    /// wrapper such as `hf.Handle(h.Get)` calls something else), the last one first. None for
    /// an anonymous function.
    static func handlerNames(_ argument: String) -> [String] {
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("(") || text.hasPrefix("{")
            || text.range(of: #"^(?:(?:func|async|function|lambda)\b|[\w$]+\s*=>)"#, options: .regularExpression) != nil { return [] }
        var references: [String] = [], calls: [String] = []
        let string = text.replacingOccurrences(of: #""[^"]*"|'[^']*'|`[^`]*`"#, with: "\"\"", options: .regularExpression) as NSString
        for match in SourceScan.regex(#"[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*"#).matches(in: string as String, range: NSRange(location: 0, length: string.length)) {
            let chain = string.substring(with: match.range)
            let after = match.range.location + match.range.length
            var next = after
            while next < string.length, SourceScan.isSpace(string.character(at: next)) { next += 1 }
            let called = next < string.length && string.character(at: next) == 40
            let last = String(chain.split(separator: ".").last ?? "").lowercased()
            if ["nil", "null", "true", "false", "this", "self", "req", "res", "ctx", "new"].contains(chain) { continue }
            if called {
                if !wrappers.contains(last) && !last.hasPrefix("apply") && !last.contains("middleware") { calls.append(chain) }
            } else {
                references.append(chain)
            }
        }
        // `X.as_view()` (Django) names the view X.
        if let view = SourceScan.matches(#"([\w.]+)\.as_view\s*\("#, in: text).first?[1] { references.append(view) }
        // A call that isn't a wrapper makes the handler: `users.Get(repo)` comes before `repo`.
        let factory = SourceScan.matches(#"^([A-Za-z_$][\w$.]*)\s*\("#, in: text).first.map { $0[1] }.flatMap { calls.contains($0) ? $0 : nil }
        var seen = Set<String>()
        return ([factory].compactMap { $0 } + references.reversed() + calls.reversed()).filter { seen.insert($0).inserted }
    }
}

/// Prefixes that apply to routes registered on a receiver: from a sub-router bound to a name,
/// within a closure (chi `Route`, Vapor `group`), or inside a function a prefix is mounted on.
struct RoutePrefixes {
    var byReceiver: [String: String] = [:]
    var scoped: [(range: NSRange, receiver: String, prefix: String)] = []
    var byFunction: [String: String] = [:]

    func prefix(receiver: String, offset: Int, function: String?) -> String {
        if let scope = scoped.filter({ NSLocationInRange(offset, $0.range) && $0.receiver == receiver }).min(by: { $0.range.length < $1.range.length }) {
            return scope.prefix
        }
        if let prefix = byReceiver[receiver] { return prefix }
        if let function, let prefix = byFunction[function] { return prefix }
        return ""
    }

    /// `r.With(auth)` → `r`; `s.mux` stays: the name routes are registered on.
    static func key(_ receiver: String) -> String {
        guard let call = receiver.firstIndex(of: "(") else { return receiver }
        let head = String(receiver[..<call])
        return head.contains(".") ? String(head[..<head.lastIndex(of: ".")!]) : head
    }
}

// MARK: - Go

enum GoRoutes {
    private static let verbs = "HandleFunc|Handle|Get|Post|Put|Patch|Delete|Head|Options|Connect|Trace|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|Any|All|Method|MethodFunc|Add|Match|Path"

    static func framework(_ imports: [String]) -> String {
        let known = [("gin-gonic/gin", "gin"), ("labstack/echo", "echo"), ("go-chi/chi", "chi"), ("gofiber/fiber", "fiber"), ("gorilla/mux", "gorilla"),
                     ("goji.io", "goji"), ("zenazn/goji", "goji"), ("julienschmidt/httprouter", "httprouter")]
        return known.first { needle, _ in imports.contains { $0.contains(needle) } }?.1 ?? "net/http"
    }

    static func find(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        let calls = file.matches(SourceScan.regex(#"\.(\#(verbs)|PathPrefix|Group|Route|Mount)\s*\("#))
        guard !calls.isEmpty else { return [] }
        let framework = framework(file.parsed.imports)
        let functions = Set(file.parsed.symbols.filter { $0.kind == "function" || $0.kind == "method" }.map(\.name))
        let routers = Set(calls.map { RoutePrefixes.key(file.receiver(before: $0.range.location)) })
        var prefixes = RoutePrefixes()

        func functionName(at offset: Int) -> String? { file.function(at: file.line(at: offset))?.name }
        func prefix(_ receiver: String, _ offset: Int) -> String {
            prefixes.prefix(receiver: RoutePrefixes.key(receiver), offset: offset, function: functionName(at: offset))
        }
        /// A pattern argument's value: `pat.Get("/x")` → ("GET", "/x"), a string expression → (nil, value).
        func pattern(_ argument: String) -> (method: String?, path: String)? {
            if argument.hasPrefix("pat."), let open = argument.firstIndex(of: "("), argument.hasSuffix(")") {
                let verb = String(argument[argument.index(argument.startIndex, offsetBy: 4)..<open])
                guard let path = file.evaluate(String(argument[argument.index(after: open)..<argument.index(before: argument.endIndex)])) else { return nil }
                return (verb == "New" ? "ANY" : verb.uppercased(), path)
            }
            guard let value = file.evaluate(argument) else { return nil }
            // Go 1.22: "GET /users/{id}", optionally with a host before the path.
            if let match = SourceScan.matches(#"^([A-Z]+)\s+(\S+)$"#, in: value).first, EndpointExtractor.methods.contains(match[1]) {
                let rest = match[2]
                return (match[1], rest.hasPrefix("/") ? rest : rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/")
            }
            return (nil, value)
        }
        /// Where a mounted handler's routes live: a sub-router's name, or a function of this file.
        func mountTarget(_ argument: String) -> (receiver: String?, function: String?) {
            var target = argument
            if let inner = SourceScan.matches(#"^http\.StripPrefix\(.*,\s*([\w.]+)\s*\)$"#, in: target).first?[1] { target = inner }
            if let name = SourceScan.matches(#"^([A-Za-z_]\w*)\s*\("#, in: target).first?[1], functions.contains(name) { return (nil, name) }
            if target.range(of: #"^[A-Za-z_][\w.]*$"#, options: .regularExpression) != nil {
                return functions.contains(target) ? (nil, target) : (target, nil)
            }
            return (nil, nil)
        }
        /// `"GET"`, `http.MethodGet` or a constant → "GET".
        func method(_ argument: String) -> String? {
            file.evaluate(argument)?.uppercased() ?? SourceScan.matches(#"Method(\w+)$"#, in: argument).first.map { $0[1].uppercased() }
        }
        func chainedMethods(_ chain: [(name: String, arguments: [NSRange], end: Int)]) -> [String] {
            let listed = chain.first { $0.name == "Methods" }?.arguments.compactMap { method(file.text($0)) } ?? []
            return listed.isEmpty ? ["ANY"] : listed
        }

        // Prefixes first (twice, so a sub-router of a sub-router gets both), then routes.
        var mounts = Set<Int>()
        for _ in 0..<2 {
            for call in calls {
                let verb = file.text(call.range(at: 1))
                let dot = call.range.location
                let open = call.range.location + call.range.length - 1
                guard let arguments = file.arguments(at: open), let first = arguments.ranges.first.map(file.text) else { continue }
                let receiver = file.receiver(before: dot)
                switch verb {
                case "PathPrefix", "Group":
                    // `api := r.PathPrefix("/api").Subrouter()`, `v1 := e.Group("/v1")`.
                    guard let value = file.evaluate(first),
                          let lhs = SourceScan.matches(#"([A-Za-z_]\w*)\s*:?=\s*$"#, in: file.lineText(before: dot - (receiver as NSString).length)).first?[1]
                    else { continue }
                    prefixes.byReceiver[lhs] = EndpointExtractor.join(prefix(receiver, dot), value)
                case "Route":
                    // chi: r.Route("/v1", func(r chi.Router) { … }).
                    guard arguments.ranges.count >= 2, let value = file.evaluate(first),
                          let parameter = SourceScan.matches(#"^func\s*\(\s*(\w+)"#, in: file.text(arguments.ranges[1])).first?[1] else { continue }
                    let full = EndpointExtractor.join(prefix(receiver, dot), value)
                    prefixes.scoped.removeAll { $0.range == arguments.ranges[1] }
                    prefixes.scoped.append((arguments.ranges[1], parameter, full))
                case "Mount", "Handle", "HandleFunc":
                    guard arguments.ranges.count == 2, let mounted = pattern(first), mounted.method == nil || mounted.method == "ANY" else { continue }
                    let value = mounted.path
                    let target = mountTarget(file.text(arguments.ranges[1]))
                    // A net/http subtree ("/static/") is a route unless a router of this file is behind it.
                    let isMount = verb == "Mount" || value.hasSuffix("/*")
                        || (value.hasSuffix("/") && value.count > 1 && (target.function != nil || target.receiver.map(routers.contains) == true))
                    guard isMount, target.receiver != nil || target.function != nil else { continue }
                    var base = value
                    if base.hasSuffix("/*") { base.removeLast(2) }
                    let full = EndpointExtractor.join(prefix(receiver, dot), base)
                    if let name = target.receiver { prefixes.byReceiver[name] = full }
                    if let name = target.function { prefixes.byFunction[name] = full }
                    mounts.insert(dot)
                default: break
                }
            }
            // A sub-router handed to a function of this file: `registerUsers(api)`.
            for match in SourceScan.matches(#"\b([A-Za-z_]\w*)\(\s*([A-Za-z_][\w.]*)\s*[,)]"#, in: file.text)
            where functions.contains(match[1]) && prefixes.byFunction[match[1]] == nil {
                if let prefix = prefixes.byReceiver[match[2]] { prefixes.byFunction[match[1]] = prefix }
            }
            // A router wrapping a sub-router: `router := newTracedRouter(cfg, api)`.
            for match in SourceScan.matches(#"\b([A-Za-z_]\w*)\s*:?=\s*[A-Za-z_][\w.]*\(([^()]*)\)"#, in: file.text) where prefixes.byReceiver[match[1]] == nil {
                let wrapped = match[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { prefixes.byReceiver[$0] }
                if wrapped.count == 1 { prefixes.byReceiver[match[1]] = wrapped[0] }
            }
        }

        var routes: [EndpointExtractor.Route] = []
        for call in calls {
            let verb = file.text(call.range(at: 1))
            let dot = call.range.location
            guard !mounts.contains(dot), !["PathPrefix", "Group", "Route", "Mount"].contains(verb) else { continue }
            let open = call.range.location + call.range.length - 1
            guard let arguments = file.arguments(at: open) else { continue }
            let texts = arguments.ranges.map(file.text)
            let receiver = file.receiver(before: dot)
            guard !receiver.isEmpty else { continue }
            var methods: [String] = []
            var path: String?
            var handler = ""
            switch verb {
            case "HandleFunc", "Handle":
                if texts.count == 3, let verb = file.evaluate(texts[0]), EndpointExtractor.methods.contains(verb) {
                    // gin: r.Handle("GET", "/x", h).
                    methods = [verb]
                    path = file.evaluate(texts[1])
                    handler = texts[2]
                } else if texts.count >= 2, let registered = pattern(texts[0]) {
                    path = registered.path
                    handler = texts[texts.count - 1]
                    // gorilla: .Methods("GET", "POST") after the registration.
                    methods = registered.method.map { [$0] } ?? chainedMethods(file.chain(after: arguments.end))
                }
            case "Path":
                // gorilla: r.Path("/x").Methods("GET").HandlerFunc(h).
                let chain = file.chain(after: arguments.end)
                guard let first = texts.first, let call = chain.first(where: { $0.name == "HandlerFunc" || $0.name == "Handler" }), let argument = call.arguments.first else { continue }
                path = file.evaluate(first)
                handler = file.text(argument)
                methods = chainedMethods(chain)
            case "Method", "MethodFunc", "Add":
                guard texts.count >= 3, let verb = method(texts[0]) else { continue }
                methods = [verb]
                path = file.evaluate(texts[1])
                handler = texts[2]
            case "Match":
                guard texts.count >= 3 else { continue }
                methods = SourceScan.matches(#""(\w+)""#, in: texts[0]).map { $0[1] }
                path = file.evaluate(texts[1])
                handler = texts[2]
            default:
                // chi, fiber, echo, gin, httprouter: r.Get("/x", h). net/http has no such methods,
                // and an HTTP client's `Post(url, contentType, body)` isn't a route.
                let last = receiver.split(separator: ".").last.map { String($0.prefix { $0 != "(" }) } ?? ""
                guard framework != "net/http", !last.lowercased().hasSuffix("client"),
                      texts.count >= 2, let value = file.evaluate(texts[0]), value.hasPrefix("/") else { continue }
                methods = [["Any", "All"].contains(verb) ? "ANY" : verb.uppercased()]
                path = value
                handler = texts[texts.count - 1]
            }
            guard var value = path, value.hasPrefix("/") || value.isEmpty, !methods.isEmpty else { continue }
            value = EndpointExtractor.join(prefix(receiver, dot), value)
            let names = EndpointExtractor.handlerNames(handler)
            for method in methods {
                routes.append(.init(method: method, path: value, line: file.line(at: dot), handler: names, framework: framework))
            }
        }
        return routes
    }
}

// MARK: - TypeScript and JavaScript

enum ScriptRoutes {
    private static let serverModules = ["express", "koa", "@koa/router", "koa-router", "fastify", "hono", "restify", "polka", "@hapi/hapi", "router"]
    /// Receivers that are HTTP clients, whose `get('/x', options)` calls out instead of serving.
    private static let clientWords: Set<String> = ["axios", "http", "https", "httpclient", "$http", "client", "request", "superagent", "got", "ky",
                                                   "fetch", "supertest", "agent", "instance", "api"]

    static func find(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        nextJS(file) + nest(file) + routers(file)
    }

    private static func framework(_ file: ExtractionInput) -> String {
        for (module, name) in [("@nestjs", "nestjs"), ("fastify", "fastify"), ("hono", "hono"), ("koa", "koa"), ("@hapi", "hapi"), ("express", "express")]
        where file.parsed.imports.contains(where: { $0.hasPrefix(module) }) { return name }
        return "express"
    }

    /// Express-style routers: `router.get('/x', auth, handler)`, `router.route('/x').get(h)`,
    /// `fastify.route({ method, url, handler })`, with `app.use('/api', router)` prefixes.
    private static func routers(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        let calls = file.matches(SourceScan.regex(#"\.(get|post|put|patch|delete|del|head|options|all|route|use)\s*\("#))
        guard !calls.isEmpty else { return [] }
        let framework = framework(file)
        var prefixes = RoutePrefixes()
        var routerNames = Set<String>()
        for match in SourceScan.matches(#"(?:const|let|var)\s+(\w+)\s*(?::\s*[\w.<>]+)?\s*=\s*(?:new\s+)?((?:express\.)?Router|express|Koa|KoaRouter|Router|Hono|fastify|Fastify|polka)\s*\(([^)]*)\)"#, in: file.text) {
            routerNames.insert(match[1])
            if let prefix = SourceScan.matches(#"prefix\s*:\s*['"`]([^'"`]+)['"`]"#, in: match[3]).first?[1] { prefixes.byReceiver[match[1]] = prefix }
        }
        let serves = !routerNames.isEmpty || file.parsed.imports.contains { module in serverModules.contains { module == $0 || module.hasPrefix($0 + "/") } }
        guard serves else { return [] }

        func isClient(_ receiver: String) -> Bool {
            receiver.lowercased().split(separator: ".").contains { clientWords.contains(String($0)) || $0.hasSuffix("client") }
        }
        // app.use('/api', router)
        for call in calls where file.text(call.range(at: 1)) == "use" {
            guard let arguments = file.arguments(at: call.range.location + call.range.length - 1), arguments.ranges.count == 2,
                  let value = file.evaluate(file.text(arguments.ranges[0])), value.hasPrefix("/") else { continue }
            let target = file.text(arguments.ranges[1])
            guard target.range(of: #"^[A-Za-z_$][\w$.]*$"#, options: .regularExpression) != nil else { continue }
            let receiver = file.receiver(before: call.range.location)
            prefixes.byReceiver[target] = EndpointExtractor.join(prefixes.prefix(receiver: RoutePrefixes.key(receiver), offset: call.range.location, function: nil), value)
        }

        var routes: [EndpointExtractor.Route] = []
        for call in calls {
            let verb = file.text(call.range(at: 1))
            guard verb != "use" else { continue }
            let dot = call.range.location
            let receiver = file.receiver(before: dot)
            let root = String(RoutePrefixes.key(receiver).split(separator: ".").first ?? "")
            guard !receiver.isEmpty, routerNames.contains(root) || !isClient(receiver),
                  let arguments = file.arguments(at: call.range.location + call.range.length - 1) else { continue }
            let texts = arguments.ranges.map(file.text)
            let prefix = prefixes.prefix(receiver: RoutePrefixes.key(receiver), offset: dot, function: nil)
            let line = file.line(at: dot)
            if verb == "route" {
                if let object = texts.first, object.hasPrefix("{") {
                    // fastify.route({ method: 'GET', url: '/x', handler }) and hapi's server.route({ method, path, handler }).
                    guard let url = SourceScan.matches(#"\b(?:url|path)\s*:\s*(['"`][^'"`]*['"`])"#, in: object).first.flatMap({ SourceScan.literal($0[1]) }) else { continue }
                    var methods = SourceScan.matches(#"\bmethod\s*:\s*['"`](\w+)['"`]"#, in: object).map { $0[1] }
                    if let list = SourceScan.matches(#"\bmethod\s*:\s*\[([^\]]*)\]"#, in: object).first?[1] { methods += SourceScan.matches(#"['"`](\w+)['"`]"#, in: list).map { $0[1] } }
                    let handler = SourceScan.matches(#"\bhandler\s*:\s*([\w$.]+)"#, in: object).first?[1] ?? (object.range(of: #"\bhandler\s*[,}]"#, options: .regularExpression) != nil ? "handler" : "")
                    for method in methods.isEmpty ? ["ANY"] : methods {
                        routes.append(.init(method: method, path: EndpointExtractor.join(prefix, url), line: line, handler: handler.isEmpty ? [] : [handler], framework: framework))
                    }
                } else if texts.count == 1, let value = file.evaluate(texts[0]), value.hasPrefix("/") {
                    // router.route('/x').get(list).post(create)
                    for link in file.chain(after: arguments.end) where EndpointExtractor.methods.contains(link.name.uppercased()) || link.name == "all" {
                        routes.append(.init(method: link.name == "all" ? "ANY" : link.name, path: EndpointExtractor.join(prefix, value), line: line,
                                            handler: link.arguments.last.map { EndpointExtractor.handlerNames(file.text($0)) } ?? [], framework: framework))
                    }
                }
                continue
            }
            // A route has a handler after the path; a client's options object would come last.
            guard texts.count >= 2, let value = file.evaluate(texts[0]), value.hasPrefix("/") || value == "*",
                  let last = texts.last, !last.hasPrefix("{") else { continue }
            routes.append(.init(method: verb == "all" ? "ANY" : verb == "del" ? "DELETE" : verb, path: EndpointExtractor.join(prefix, value), line: line,
                                handler: EndpointExtractor.handlerNames(last), framework: framework))
        }
        return routes
    }

    /// NestJS: `@Get(':id')` on a method of a `@Controller('users')` class.
    private static func nest(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        guard file.text.contains("@Controller") else { return [] }
        var controllers: [(offset: Int, prefix: String)] = []
        for match in file.matches(SourceScan.regex(#"@Controller\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1) else { continue }
            let first = arguments.ranges.first.map(file.text) ?? ""
            let prefix = SourceScan.literal(first) ?? SourceScan.matches(#"path\s*:\s*(['"`][^'"`]*['"`])"#, in: first).first.flatMap { SourceScan.literal($0[1]) } ?? ""
            controllers.append((match.range.location, prefix))
        }
        var routes: [EndpointExtractor.Route] = []
        for match in file.matches(SourceScan.regex(#"@(Get|Post|Put|Patch|Delete|Head|Options|All)\s*\("#)) {
            guard let controller = controllers.last(where: { $0.offset < match.range.location }),
                  let arguments = file.arguments(at: match.range.location + match.range.length - 1) else { continue }
            let sub = arguments.ranges.first.flatMap { SourceScan.literal(file.text($0)) } ?? ""
            let line = file.line(at: match.range.location)
            let handler = file.symbol(after: line).map { [$0.id] } ?? []
            let verb = file.text(match.range(at: 1))
            routes.append(.init(method: verb == "All" ? "ANY" : verb, path: EndpointExtractor.join("/" + controller.prefix, sub), line: line, handler: handler, framework: "nestjs"))
        }
        return routes
    }

    /// Next.js: `pages/api/**` files and `app/**/route.ts` handlers exported per method.
    private static func nextJS(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        let parts = file.path.split(separator: "/").map(String.init)
        let base = (file.fileName as NSString).deletingPathExtension
        if let pages = parts.firstIndex(of: "pages"), pages + 2 < parts.count, parts[pages + 1] == "api" {
            var segments = Array(parts[(pages + 1)..<(parts.count - 1)]) + [base]
            if base == "index" { segments.removeLast() }
            let handler = file.parsed.symbols.firstIndex { $0.signature.contains("export default") } ?? file.parsed.symbols.firstIndex { $0.name == "handler" }
            return [.init(method: "ANY", path: "/" + segments.joined(separator: "/"), line: 1, handler: handler.map { [file.symbolIDs[$0]] } ?? [], framework: "nextjs")]
        }
        guard base == "route", let app = parts.lastIndex(of: "app"), app < parts.count - 1 else { return [] }
        let segments = parts[(app + 1)..<(parts.count - 1)].filter { !($0.hasPrefix("(") && $0.hasSuffix(")")) && !$0.hasPrefix("@") }
        return file.parsed.symbols.indices.compactMap { index in
            let symbol = file.parsed.symbols[index]
            guard symbol.container.isEmpty, EndpointExtractor.methods.contains(symbol.name), symbol.signature.contains("export") else { return nil }
            return .init(method: symbol.name, path: "/" + segments.joined(separator: "/"), line: symbol.line, handler: [file.symbolIDs[index]], framework: "nextjs")
        }
    }
}

// MARK: - Python

enum PythonRoutes {
    static func find(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        decorated(file) + django(file)
    }

    /// Flask and FastAPI: `@app.route('/x', methods=[…])`, `@router.get('/x')`, with Blueprint and
    /// APIRouter prefixes set in the file.
    private static func decorated(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        let decorators = file.matches(SourceScan.regex(#"(?m)^[ \t]*@([\w.]+)\.(route|get|post|put|patch|delete|head|options|api_route)\s*\("#))
        guard !decorators.isEmpty else { return [] }
        let framework = file.parsed.imports.contains { $0.hasPrefix("fastapi") } ? "fastapi" : file.parsed.imports.contains { $0.hasPrefix("flask") } ? "flask" : "python"
        var prefixes: [String: String] = [:]
        func keyword(_ name: String, in arguments: [String]) -> String? {
            arguments.first { $0.hasPrefix(name + "=") || $0.hasPrefix(name + " =") }.flatMap { argument in
                argument.firstIndex(of: "=").flatMap { SourceScan.literal(argument[argument.index(after: $0)...].trimmingCharacters(in: .whitespaces)) }
            }
        }
        for match in file.matches(SourceScan.regex(#"(?m)^\s*(\w+)\s*=\s*(?:[\w.]+\.)?(?:Blueprint|APIRouter)\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1) else { continue }
            if let prefix = keyword("url_prefix", in: arguments.ranges.map(file.text)) ?? keyword("prefix", in: arguments.ranges.map(file.text)) {
                prefixes[file.text(match.range(at: 1))] = prefix
            }
        }
        for match in file.matches(SourceScan.regex(#"\.(?:register_blueprint|include_router)\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1), let target = arguments.ranges.first.map(file.text) else { continue }
            if let prefix = keyword("url_prefix", in: arguments.ranges.map(file.text)) ?? keyword("prefix", in: arguments.ranges.map(file.text)) {
                prefixes[target] = EndpointExtractor.join(prefix, prefixes[target] ?? "")
            }
        }
        var routes: [EndpointExtractor.Route] = []
        for match in decorators {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1), let first = arguments.ranges.first,
                  let path = SourceScan.literal(file.text(first)) ?? file.evaluate(file.text(first)) else { continue }
            let texts = arguments.ranges.map(file.text)
            let verb = file.text(match.range(at: 2))
            var methods = [verb.uppercased()]
            if verb == "route" || verb == "api_route" {
                let list = texts.first { $0.hasPrefix("methods") }.map { SourceScan.matches(#"['"](\w+)['"]"#, in: $0).map { $0[1] } } ?? []
                methods = list.isEmpty ? ["GET"] : list
            }
            let line = file.line(at: match.range.location)
            let handler = file.symbol(after: line).map { [$0.id] } ?? []
            let receiver = file.text(match.range(at: 1))
            for method in methods {
                routes.append(.init(method: method, path: EndpointExtractor.join(prefixes[receiver] ?? "", path), line: line, handler: handler, framework: framework))
            }
        }
        return routes
    }

    /// Django: `path('users/<int:pk>/', views.detail)` and `re_path(r'^…$', …)` in URL modules.
    private static func django(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        guard file.fileName == "urls.py" || file.text.contains("urlpatterns") else { return [] }
        var routes: [EndpointExtractor.Route] = []
        for match in file.matches(SourceScan.regex(#"(?<![\w.])(path|re_path|url)\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1), arguments.ranges.count >= 2,
                  var route = SourceScan.literal(file.text(arguments.ranges[0])) else { continue }
            let view = file.text(arguments.ranges[1])
            guard !view.hasPrefix("include") else { continue }
            if route.hasPrefix("^") { route.removeFirst() }
            routes.append(.init(method: "ANY", path: "/" + route, line: file.line(at: match.range.location), handler: EndpointExtractor.handlerNames(view), framework: "django"))
        }
        return routes
    }
}

// MARK: - Swift (Vapor)

enum VaporRoutes {
    static func find(_ file: ExtractionInput) -> [EndpointExtractor.Route] {
        guard file.parsed.imports.contains("Vapor") else { return [] }
        var prefixes = RoutePrefixes()
        func components(_ ranges: [NSRange]) -> [String] {
            ranges.map(file.text).prefix { !$0.contains(":") || SourceScan.literal($0) != nil }.compactMap(SourceScan.literal)
        }
        // let users = routes.grouped("users"); routes.group("admin") { admin in … }
        for match in file.matches(SourceScan.regex(#"let\s+(\w+)\s*=\s*([\w.]+)\.grouped\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1) else { continue }
            let parent = prefixes.prefix(receiver: file.text(match.range(at: 2)), offset: match.range.location, function: nil)
            prefixes.byReceiver[file.text(match.range(at: 1))] = EndpointExtractor.join(parent, "/" + components(arguments.ranges).joined(separator: "/"))
        }
        for match in file.matches(SourceScan.regex(#"([\w.]+)\.group\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1) else { continue }
            let rest = file.string.substring(from: arguments.end)
            guard let parameter = SourceScan.matches(#"^\s*\{\s*(\w+)\s+in"#, in: String(rest.prefix(80))).first?[1] else { continue }
            let brace = arguments.end + (rest as NSString).range(of: "{").location
            guard let end = file.closing(at: brace) else { continue }
            let parent = prefixes.prefix(receiver: file.text(match.range(at: 1)), offset: match.range.location, function: nil)
            prefixes.scoped.append((NSRange(location: brace, length: end - brace), parameter, EndpointExtractor.join(parent, "/" + components(arguments.ranges).joined(separator: "/"))))
        }
        var routes: [EndpointExtractor.Route] = []
        for match in file.matches(SourceScan.regex(#"\.(get|post|put|patch|delete|on)\s*\("#)) {
            guard let arguments = file.arguments(at: match.range.location + match.range.length - 1) else { continue }
            var texts = arguments.ranges.map(file.text)
            let receiver = file.receiver(before: match.range.location)
            var method = file.text(match.range(at: 1)).uppercased()
            if method == "ON" {
                guard let first = texts.first, first.hasPrefix(".") else { continue }
                method = String(first.dropFirst()).uppercased()
                texts.removeFirst()
            }
            let handler = texts.first { $0.hasPrefix("use:") }.map { String($0.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            let trailing = String(file.string.substring(from: arguments.end).prefix(60))
            guard handler != nil || trailing.range(of: #"^\s*\{\s*(?:\(?\w+(?:\s*:\s*[\w.]+)?\)?\s*(?:async\s*)?(?:throws\s*)?(?:->\s*[\w.<>?\[\]]+\s*)?in\b|\$0)"#,
                                                   options: .regularExpression) != nil,
                  !receiver.isEmpty else { continue }
            let pathParts = texts.prefix { !$0.hasPrefix("use:") }.compactMap(SourceScan.literal)
            guard pathParts.count == texts.prefix(while: { !$0.hasPrefix("use:") }).count else { continue }
            let prefix = prefixes.prefix(receiver: RoutePrefixes.key(receiver), offset: match.range.location, function: nil)
            routes.append(.init(method: method, path: EndpointExtractor.join(prefix, "/" + pathParts.joined(separator: "/")), line: file.line(at: match.range.location),
                                handler: handler.map(EndpointExtractor.handlerNames) ?? [], framework: "vapor"))
        }
        return routes
    }
}
