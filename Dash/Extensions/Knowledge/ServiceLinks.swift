import Foundation
import SQLite3

/// The pass across repositories, after any of them is indexed: which service a host stands for
/// (`host —about→ service` by name, besides the ones Ingresses and HTTPRoutes say), which defined route a call no repository defines is likely to
/// reach (`calls_endpoint`, weighted below 1), which gRPC service code implements or calls
/// (refs by service name), which topic a Pub/Sub subscription named after it consumes, and which
/// table code reads or writes (refs by table name). Reads the graph only; its edges, under the
/// source "service-links", are replaced wholesale each time.
enum ServiceLinks {
    static let source = "service-links"
    /// Refs only this pass resolves: they name something any repository may define.
    static let refKinds: Set<String> = ["implements", "calls_rpc"]

    static func link(store: KnowledgeStore, sharedKinds: [String] = CodeExtractors.all.flatMap(\.sharedKinds)) async throws {
        // Its own edges go first: they mustn't keep a host or a route nothing else reaches alive.
        try await store.removeEdges(source: source)
        try await store.pruneShared(kinds: sharedKinds)
        try await store.settleCalledEndpoints()

        let services = try await store.nodes(kind: "service", limit: 100_000)
        let hosts = try await store.nodes(kind: "host", limit: 100_000)
        var edges: [KnowledgeEdge] = []
        var hostServices: [String: [String]] = [:]
        for host in hosts {
            let matches = serviceMatches(host: host.name, services: services)
            hostServices[host.id] = matches.ids
            edges += matches.ids.map { KnowledgeEdge(src: host.id, dst: $0, kind: "about", weight: matches.weight, source: source) }
        }
        // Hosts an Ingress or HTTPRoute routes to a service (the link pass's edges) are known exactly.
        for (host, service) in try await store.pairs(kind: "about", dstPrefix: "service:") where host.hasPrefix("host:") {
            if !(hostServices[host] ?? []).contains(service) { hostServices[host, default: []].append(service) }
        }

        let defined = try await store.definedEndpoints()
        let unresolved = try await store.unresolvedCalls()
        if !defined.isEmpty && !unresolved.isEmpty {
            let exposedBy = Dictionary(grouping: try await store.pairs(kind: "exposes", dstPrefix: "endpoint:"), by: \.dst).mapValues { $0.map(\.src) }
            let callerHosts = Dictionary(grouping: try await store.pairs(kind: "calls_host", dstPrefix: "host:"), by: \.src).mapValues { $0.map(\.dst) }
            let routes = defined.compactMap(Route.init)
            for (caller, endpoint) in unresolved {
                guard let call = Route(endpoint) else { continue }
                let services = Set((callerHosts[caller] ?? []).flatMap { hostServices[$0] ?? [] })
                edges += match(call, routes: routes, services: services, exposedBy: exposedBy).map {
                    KnowledgeEdge(src: caller, dst: $0.id, kind: "calls_endpoint", weight: $0.weight, source: source)
                }
            }
        }

        let rpcServices = try await store.nodes(kind: "rpc_service", limit: 100_000)
        if !rpcServices.isEmpty {
            let byName = Dictionary(grouping: rpcServices, by: \.name)
            for ref in try await store.refs(kinds: refKinds) { edges += rpcTargets(ref, services: byName) }
        }

        let topics = try await store.nodes(kind: "topic", limit: 100_000)
        if topics.contains(where: { $0.signature.hasPrefix("Pub/Sub subscription") }) {
            let declared = Set(try await store.pairs(kind: "consumes", dstPrefix: "topic:pubsub:").map(\.src).filter { $0.hasPrefix("topic:") })
            edges += subscriptionTopics(topics, declared: declared)
        }

        let accesses = try await store.tableAccesses()
        if !accesses.isEmpty {
            let tables = TableHistory.resolve(accesses, defined: try await store.definedTables(), source: source)
            try await store.insertMissing(tables.placeholders)
            edges += tables.edges
        }
        try await store.upsert(edges)
    }

    // MARK: Messaging

    /// Pub/Sub subscriptions no declaration ties to their topic, named after it (`events-sub`,
    /// `events-subscription`, `events_sub`): `consumes` that topic at 0.6.
    static func subscriptionTopics(_ topics: [KnowledgeNode], declared: Set<String>) -> [KnowledgeEdge] {
        let pubsub = topics.filter { $0.language == "pubsub" }
        let topicIDs = Set(pubsub.filter { !$0.signature.hasPrefix("Pub/Sub subscription") }.map(\.id))
        var edges: [KnowledgeEdge] = []
        for subscription in pubsub where subscription.signature.hasPrefix("Pub/Sub subscription") && !declared.contains(subscription.id) {
            for suffix in ["-subscription", "_subscription", ".subscription", "-sub", "_sub", ".sub"] where subscription.name.hasSuffix(suffix) {
                let topic = MessagingExtractor.id("pubsub", String(subscription.name.dropLast(suffix.count)))
                if topicIDs.contains(topic) { edges.append(KnowledgeEdge(src: subscription.id, dst: topic, kind: "consumes", weight: 0.6, source: source)) }
                break
            }
        }
        return edges
    }

    // MARK: gRPC

    /// The gRPC service a ref names: its first candidate name some `.proto` declares; between
    /// services of that name, the ones whose package the Go import path spells out. One at 0.9,
    /// two or three at 0.3 each, more none.
    static func rpcTargets(_ ref: KnowledgeRef, services byName: [String: [KnowledgeNode]]) -> [KnowledgeEdge] {
        let importPath = ref.names.first { $0.hasPrefix("import:") }.map { String($0.dropFirst("import:".count)) }
        for name in ref.names where !name.hasPrefix("import:") {
            guard var candidates = byName[name], !candidates.isEmpty else { continue }
            if candidates.count > 1, let importPath {
                let segments = Set(importPath.lowercased().split { "/.;-_".contains($0) }.map(String.init))
                let scored = candidates.map { node in (node, node.qualified.lowercased().split(separator: ".").dropLast().filter { segments.contains(String($0)) }.count) }
                let best = scored.map(\.1).max() ?? 0
                if best > 0 { candidates = scored.filter { $0.1 == best }.map(\.0) }
            }
            let weight = candidates.count == 1 ? 0.9 : candidates.count <= 3 ? 0.3 : 0
            guard weight > 0 else { return [] }
            return candidates.map { KnowledgeEdge(src: ref.src, dst: $0.id, kind: ref.kind, weight: weight, source: source) }
        }
        return []
    }

    // MARK: Hosts

    /// Services a host's name stands for: equal names (case and punctuation aside) at 0.9, split
    /// between up to three services of that name; else the one service equal once generic words
    /// ("api", "service", …) are dropped, at 0.6.
    static func serviceMatches(host: String, services: [KnowledgeNode]) -> (ids: [String], weight: Double) {
        let words = hostWords(host)
        guard !words.isEmpty else { return ([], 0) }
        let exact = services.filter { nameWords($0.name) == words }
        if (1...3).contains(exact.count) { return (exact.map(\.id), 0.9 / Double(exact.count)) }
        guard exact.isEmpty else { return ([], 0) }
        let core = words.filter { !genericWords.contains($0) }
        guard core.joined().count >= 3 else { return ([], 0) }
        let loose = services.filter { nameWords($0.name).filter { !genericWords.contains($0) } == core }
        return loose.count == 1 ? ([loose[0].id], 0.6) : ([], 0)
    }

    static let genericWords: Set<String> = ["api", "apis", "service", "services", "svc", "server", "srv", "http", "https", "app", "backend", "internal"]
    private static let variablePrefixes = ["NEXT_PUBLIC_", "REACT_APP_", "VITE_", "VUE_APP_", "NUXT_PUBLIC_", "PUBLIC_"]
    private static let variableSuffixes: Set<String> = ["URL", "URI", "HOST", "HOSTNAME", "ADDR", "ADDRESS", "ENDPOINT", "BASE", "ROOT", "ORIGIN", "DOMAIN", "PORT", "PROTOCOL", "SCHEME"]

    /// "BILLING_API_URL" → [billing, api]; "billing-api.default.svc.cluster.local" → [billing, api].
    static func hostWords(_ name: String) -> [String] {
        if name.contains(where: \.isUppercase) || name.contains("_") {
            var variable = name.uppercased()
            for prefix in variablePrefixes where variable.hasPrefix(prefix) { variable.removeFirst(prefix.count) }
            var words = variable.split(separator: "_").map(String.init)
            while words.count > 1, let last = words.last, variableSuffixes.contains(last) { words.removeLast() }
            return words.map { $0.lowercased() }
        }
        guard name != "localhost", name.range(of: #"^[\d.]+$"#, options: .regularExpression) == nil else { return [] }
        return nameWords(String(name.split(separator: ".").first ?? ""))
    }

    /// A service's name as lowercase words: "@acme/billing-api" → [billing, api], "BillingAPI" → [billing, api].
    static func nameWords(_ name: String) -> [String] {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        let spaced = base.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: Routes

    struct Route {
        var id: String
        var method: String
        var segments: [Substring]

        init?(_ id: String) {
            let body = id.dropFirst("endpoint:".count)
            guard let space = body.firstIndex(of: " ") else { return nil }
            self.id = id
            method = String(body[..<space])
            segments = body[body.index(after: space)...].split(separator: "/")
        }
    }

    /// Defined routes a call may reach once `{}` matches any segment both ways (and at least one
    /// literal one matches): the same number of segments at 0.8, or one path ending the other
    /// (the shorter with two segments or more, as when a client's base URL carries a prefix) at
    /// 0.6. Among the services the caller's hosts stand for, when they expose a match, at 0.9.
    /// Two or three candidates get 0.3 each; more, none.
    static func match(_ call: Route, routes: [Route], services: Set<String>, exposedBy: [String: [String]]) -> [(id: String, weight: Double)] {
        var full: [String] = []
        var suffix: [String] = []
        for route in routes where route.id != call.id && (route.method == call.method || route.method == "ANY" || call.method == "ANY") {
            if route.segments.count == call.segments.count {
                if matches(call.segments[...], route.segments[...]) { full.append(route.id) }
            } else {
                let (short, long) = route.segments.count < call.segments.count ? (route.segments, call.segments) : (call.segments, route.segments)
                if short.count >= 2, matches(short[...], long.suffix(short.count)) { suffix.append(route.id) }
            }
        }
        if !services.isEmpty {
            let served = (full + suffix).filter { !services.isDisjoint(with: exposedBy[$0] ?? []) }
            if (1...3).contains(served.count) { return served.map { ($0, 0.9 / Double(served.count)) } }
        }
        let (candidates, weight) = !full.isEmpty ? (full, 0.8) : (suffix, 0.6)
        switch candidates.count {
        case 1: return [(candidates[0], weight)]
        case 2...3: return candidates.map { ($0, 0.3) }
        default: return []
        }
    }

    private static func matches(_ a: ArraySlice<Substring>, _ b: ArraySlice<Substring>) -> Bool {
        var literal = false
        for (x, y) in zip(a, b) {
            if x == "{}" || y == "{}" { continue }
            guard x == y else { return false }
            if !x.contains("{}") && x != "*" { literal = true }
        }
        return literal
    }
}

extension KnowledgeStore {
    /// Refs of some kinds in every repository.
    func refs(kinds: Set<String>) throws -> [KnowledgeRef] {
        let list = kinds.sorted().map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")
        let statement = try prepare("SELECT src, kind, names, line FROM refs WHERE kind IN (\(list))")
        defer { sqlite3_finalize(statement) }
        var result: [KnowledgeRef] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(KnowledgeRef(src: text(statement, 0), kind: text(statement, 1), names: text(statement, 2).components(separatedBy: "\n"),
                                       line: Int(sqlite3_column_int64(statement, 3))))
        }
        return result
    }

    /// Endpoints some file defines (a route or an OpenAPI operation).
    func definedEndpoints() throws -> [String] {
        try strings("SELECT DISTINCT src FROM edges WHERE src >= 'endpoint:' AND src < 'endpoint;' AND kind = 'defined_in'", [])
    }

    /// (caller, endpoint) for calls to endpoints no file defines.
    func unresolvedCalls() throws -> [(src: String, dst: String)] {
        try pairs("""
            SELECT e.src, e.dst FROM edges e WHERE e.dst >= 'endpoint:' AND e.dst < 'endpoint;' AND e.kind = 'calls_endpoint'
            AND NOT EXISTS (SELECT 1 FROM edges d WHERE d.src = e.dst AND d.kind = 'defined_in')
            """, [])
    }

    /// (src, dst) of the edges of a kind whose target id starts with `dstPrefix`.
    func pairs(kind: String, dstPrefix: String) throws -> [(src: String, dst: String)] {
        let end = String(dstPrefix.dropLast()) + String(UnicodeScalar(dstPrefix.unicodeScalars.last!.value + 1)!)
        return try pairs("SELECT src, dst FROM edges WHERE dst >= ?1 AND dst < ?2 AND kind = ?3", [dstPrefix, end, kind])
    }

    func pairs(_ sql: String, _ values: [Any?]) throws -> [(src: String, dst: String)] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append((text(statement, 0), text(statement, 1))) }
        return result
    }
}
