import DashKit
import Foundation
import NaturalLanguage
import SQLite3

/// What the knowledge graph works out from the indexed code, beyond parsing: modules (clusters of
/// files that belong together), entry points and the flows they start, hotspots, import cycles,
/// configuration (environment variables read and set), decisions (ADRs), and vectors for search by
/// meaning. Recomputed per repository after indexing; everything here is derived and replaceable.
enum KnowledgeAnalysis {
    /// Derived nodes and edges are written under this source, replaced wholesale each time.
    static let source = "analysis"

    // MARK: Clusters (Louvain)

    /// Groups nodes so that edges fall inside groups more than chance would (modularity), two
    /// levels of Louvain. `edges` are undirected and weighted; returns node → group number.
    static func clusters(_ edges: [(String, String, Double)]) -> [String: Int] {
        var nodes = Set<String>()
        for (a, b, _) in edges { nodes.insert(a); nodes.insert(b) }
        var assignment = Dictionary(uniqueKeysWithValues: nodes.sorted().enumerated().map { ($1, $0) })
        var graph = edges.filter { $0.0 != $0.1 }.map { (assignment[$0.0]!, assignment[$0.1]!, $0.2) }
        var members: [Int: Set<String>] = Dictionary(uniqueKeysWithValues: assignment.map { ($1, [$0]) })
        for _ in 0..<3 {
            let moved = localMoving(graph, count: members.count)
            let groups = Set(moved.values)
            guard groups.count < members.count else { break }
            // Aggregate: each community becomes a node.
            let renumber = Dictionary(uniqueKeysWithValues: groups.sorted().enumerated().map { ($1, $0) })
            var nextMembers: [Int: Set<String>] = [:]
            for (node, set) in members { nextMembers[renumber[moved[node] ?? node]!, default: []].formUnion(set) }
            var weights: [Int: [Int: Double]] = [:]
            for (a, b, w) in graph {
                let x = renumber[moved[a] ?? a]!, y = renumber[moved[b] ?? b]!
                weights[min(x, y), default: [:]][max(x, y), default: 0] += w
            }
            graph = weights.flatMap { a, row in row.map { (a, $0.key, $0.value) } }
            members = nextMembers
        }
        for (group, set) in members { for node in set { assignment[node] = group } }
        return assignment
    }

    /// One Louvain phase: move each node to the neighbouring group that gains the most modularity.
    private static func localMoving(_ edges: [(Int, Int, Double)], count: Int) -> [Int: Int] {
        var adjacency: [Int: [Int: Double]] = [:]
        var degree = [Double](repeating: 0, count: count)
        var total = 0.0
        for (a, b, w) in edges {
            if a == b { degree[a] += 2 * w; total += w; adjacency[a, default: [:]][a, default: 0] += w; continue }
            adjacency[a, default: [:]][b, default: 0] += w
            adjacency[b, default: [:]][a, default: 0] += w
            degree[a] += w; degree[b] += w; total += w
        }
        guard total > 0 else { return Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, $0) }) }
        var community = Array(0..<count)
        var communityDegree = degree
        var improved = true
        var passes = 0
        while improved && passes < 20 {
            improved = false
            passes += 1
            for node in 0..<count {
                let current = community[node]
                var links: [Int: Double] = [:]
                for (neighbor, w) in adjacency[node] ?? [:] where neighbor != node { links[community[neighbor], default: 0] += w }
                communityDegree[current] -= degree[node]
                var best = current
                var bestGain = (links[current] ?? 0) - communityDegree[current] * degree[node] / (2 * total)
                for (candidate, w) in links where candidate != current {
                    let gain = w - communityDegree[candidate] * degree[node] / (2 * total)
                    if gain > bestGain + 1e-12 { best = candidate; bestGain = gain }
                }
                communityDegree[best] += degree[node]
                if best != current { community[node] = best; improved = true }
            }
        }
        return Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, community[$0]) })
    }

    /// A readable name for a group of file paths: their longest common directory, else the most
    /// common one.
    static func name(of paths: [String]) -> String {
        let parts = paths.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) }
        guard var common = parts.first else { return "module" }
        for path in parts.dropFirst() {
            common = Array(zip(common, path).prefix { $0 == $1 }.map(\.0))
        }
        if !common.isEmpty { return common.joined(separator: "/") }
        let counts = Dictionary(grouping: parts.compactMap { $0.prefix(2).joined(separator: "/") }.filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? "root"
    }

    // MARK: Cycles (Tarjan)

    /// Strongly connected components with more than one node: import cycles.
    static func cycles(_ edges: [(String, String)]) -> [[String]] {
        var adjacency: [String: [String]] = [:]
        for (a, b) in edges where a != b { adjacency[a, default: []].append(b) }
        var index = 0
        var indices: [String: Int] = [:], lowlink: [String: Int] = [:]
        var stack: [String] = [], onStack = Set<String>()
        var result: [[String]] = []
        func connect(_ v: String) {
            indices[v] = index; lowlink[v] = index; index += 1
            stack.append(v); onStack.insert(v)
            for w in adjacency[v] ?? [] {
                if indices[w] == nil { connect(w); lowlink[v] = min(lowlink[v]!, lowlink[w]!) }
                else if onStack.contains(w) { lowlink[v] = min(lowlink[v]!, indices[w]!) }
            }
            if lowlink[v] == indices[v] {
                var component: [String] = []
                while let w = stack.popLast() { onStack.remove(w); component.append(w); if w == v { break } }
                if component.count > 1 { result.append(component.sorted()) }
            }
        }
        for v in adjacency.keys.sorted() where indices[v] == nil { connect(v) }
        return result.sorted { $0.count > $1.count }
    }

    // MARK: Entry points and flows

    /// Whether a symbol starts work from outside: a main, an HTTP/CLI/RPC handler, a test-free
    /// exported command. `signature` is its declaration line.
    static func isEntryPoint(name: String, signature: String, path: String) -> Bool {
        let lower = signature.lowercased()
        if ["main", "run", "execute"].contains(name.lowercased()) && (path.contains("cmd/") || path.contains("main.") || name == "main") { return true }
        if signature.contains("@main") || signature.contains("ServeHTTP") || signature.contains("http.ResponseWriter") { return true }
        if lower.contains("@app.route") || lower.contains("@router.") || lower.contains("@get(") || lower.contains("@post(") { return true }
        if signature.contains("(req, res") || signature.contains("(request: Request") || signature.contains("(c *gin.Context") || signature.contains("(c echo.Context") { return true }
        if lower.hasPrefix("func handle") || name.hasPrefix("Handle") || name.hasSuffix("Handler") && signature.contains("func") { return true }
        return false
    }

    /// The flow an entry point starts: its callees breadth-first, the strongest few per step,
    /// up to `depth` hops. `callees` gives (callee, confidence) for a symbol.
    static func flow(from entry: String, depth: Int = 5, perStep: Int = 3, limit: Int = 25,
                     callees: (String) -> [(String, Double)]) -> [String] {
        var steps = [entry], seen: Set<String> = [entry], frontier = [entry]
        for _ in 0..<depth {
            var next: [String] = []
            for node in frontier {
                for (callee, _) in callees(node).sorted(by: { $0.1 > $1.1 }).prefix(perStep) where seen.insert(callee).inserted {
                    steps.append(callee)
                    next.append(callee)
                    if steps.count >= limit { return steps }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return steps
    }

    // MARK: Configuration

    /// Environment variables a code file reads (Go, JS/TS, Python, Swift, Kotlin/Java, Rust).
    static func environmentReads(_ text: String) -> Set<String> {
        let patterns = [
            #"os\.(?:Getenv|LookupEnv)\("([A-Z][A-Z0-9_]{1,})"\)"#,
            #"process\.env\.([A-Z][A-Z0-9_]{1,})"#, #"process\.env\[["']([A-Z][A-Z0-9_]{1,})["']\]"#,
            #"os\.(?:environ\.get|getenv)\(["']([A-Z][A-Z0-9_]{1,})["']"#, #"os\.environ\[["']([A-Z][A-Z0-9_]{1,})["']\]"#,
            #"environment\[["]([A-Z][A-Z0-9_]{1,})["]\]"#, #"System\.getenv\("([A-Z][A-Z0-9_]{1,})"\)"#,
            #"env::var\("([A-Z][A-Z0-9_]{1,})"\)"#, #"envconfig:"([A-Z][A-Z0-9_]{1,})""#, #"env:"([A-Z][A-Z0-9_]{1,})""#,
        ]
        return matches(patterns, in: text)
    }

    /// Environment variables a configuration file sets: Kubernetes/compose `env`, `.env` files,
    /// Terraform/Helm values that look like variables.
    static func environmentSets(_ text: String, path: String) -> Set<String> {
        let name = (path as NSString).lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") {
            return matches([#"(?m)^\s*(?:export\s+)?([A-Z][A-Z0-9_]{1,})\s*="#], in: text)
        }
        return matches([#"(?m)-\s*name:\s*["']?([A-Z][A-Z0-9_]{2,})["']?\s*$"#,
                        #"(?m)^\s+([A-Z][A-Z0-9_]{2,}):\s*\S"#,
                        #"(?m)^\s*-\s*([A-Z][A-Z0-9_]{2,})=\S"#], in: text)
    }

    // MARK: Decisions

    /// An architecture decision record: under adr/ or decisions/, or titled "ADR…"/"Decision…".
    static func isDecision(path: String, text: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/adr/") || lower.hasPrefix("adr/") || lower.contains("/adrs/") || lower.contains("/decisions/") || lower.hasPrefix("decisions/") { return true }
        let title = text.split(separator: "\n").first { $0.hasPrefix("# ") }?.lowercased() ?? ""
        return title.hasPrefix("# adr") || title.contains("decision record") || title.hasPrefix("# decision")
    }

    /// The title, status and date of a decision record, and the code it names (`backticked`
    /// paths or identifiers).
    static func decision(_ text: String) -> (title: String, status: String, date: String, mentions: Set<String>) {
        let lines = text.split(separator: "\n").map(String.init)
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "Decision"
        var status = ""
        if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix("## status") || $0.lowercased().hasPrefix("status:") }) {
            let inline = lines[index].split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            status = inline.isEmpty ? (lines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "") : inline
        }
        let date = firstMatch(#"(\d{4}-\d{2}-\d{2})"#, in: text) ?? ""
        let mentions = matches([#"`([A-Za-z0-9_./-]{3,})`"#], in: text)
        return (title, status.trimmingCharacters(in: .whitespaces), date, mentions)
    }

    // MARK: Vectors

    /// "PodsFeature.refreshPods" → "pods feature refresh pods": embeddings read words.
    static func words(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if character == "_" || character == "." || character == "/" || character == "-" { result.append(" ") }
            else if let previous, character.isUppercase, previous.isLowercase || previous.isNumber { result.append(" "); result.append(character) }
            else { result.append(character) }
            previous = character
        }
        return result.lowercased()
    }

    /// A sentence vector for search by meaning (Apple's on-device embedding; nothing leaves the Mac).
    static func embed(_ text: String) -> [Float]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english), let vector = embedding.vector(for: text) else { return nil }
        return vector.map { Float($0) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Reciprocal-rank fusion of ranked id lists (k = 60).
    static func fuse(_ rankings: [[String]], k: Double = 60) -> [String] {
        var scores: [String: Double] = [:]
        for ranking in rankings { for (rank, id) in ranking.enumerated() { scores[id, default: 0] += 1 / (k + Double(rank + 1)) } }
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    // MARK: Helpers

    static func matches(_ patterns: [String], in text: String) -> Set<String> {
        var found = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                if let group = Range(match.range(at: 1), in: text) { found.insert(String(text[group])) }
            }
        }
        return found
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Store queries for the analyses

extension KnowledgeStore {
    /// File-level relations of a repository, undirected for clustering: imports, calls between
    /// files (summed confidence) and co-change.
    func fileRelations(repo: String) throws -> [(String, String, Double)] {
        var result: [(String, String, Double)] = []
        let queries = [
            "SELECT a.path, b.path, 1.0 FROM edges e JOIN nodes a ON a.id = e.src JOIN nodes b ON b.id = e.dst WHERE a.repo = ?1 AND a.kind = 'file' AND b.kind = 'file' AND e.kind = 'imports'",
            "SELECT a.path, b.path, SUM(e.weight) FROM edges e JOIN nodes a ON a.id = e.src JOIN nodes b ON b.id = e.dst WHERE e.kind = 'calls' AND a.repo = ?1 AND b.repo = ?1 AND a.path != b.path GROUP BY a.path, b.path",
            "SELECT a.path, b.path, MIN(e.weight, 5) * 0.5 FROM edges e JOIN nodes a ON a.id = e.src JOIN nodes b ON b.id = e.dst WHERE e.kind = 'changes_with' AND a.repo = ?1 AND a.kind = 'file' AND b.kind = 'file'",
        ]
        for sql in queries {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(statement, [repo])
            while sqlite3_step(statement) == SQLITE_ROW { result.append((text(statement, 0), text(statement, 1), sqlite3_column_double(statement, 2))) }
        }
        return result
    }

    /// path → a number per file: incoming calls (`calls`) or commits (`authored`).
    func perFile(repo: String, edgeKind: String) throws -> [String: Double] {
        let statement = try prepare("SELECT b.path, SUM(e.weight) FROM edges e JOIN nodes b ON b.id = e.dst WHERE e.kind = ?2 AND b.repo = ?1 GROUP BY b.path")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo, edgeKind])
        var result: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0)] = sqlite3_column_double(statement, 1) }
        return result
    }

    /// Callees of a symbol with their confidence.
    func callees(_ id: String) throws -> [(String, Double)] {
        let statement = try prepare("SELECT dst, weight FROM edges WHERE src = ?1 AND kind = 'calls'")
        defer { sqlite3_finalize(statement) }
        bind(statement, [id])
        var result: [(String, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append((text(statement, 0), sqlite3_column_double(statement, 1))) }
        return result
    }

    /// Symbols of a repository with no incoming calls (candidate entry points), with signatures.
    func uncalledSymbols(repo: String) throws -> [KnowledgeNode] {
        try nodes("SELECT * FROM nodes n WHERE n.repo = ?1 AND n.kind = 'symbol' AND NOT EXISTS (SELECT 1 FROM edges e WHERE e.dst = n.id AND e.kind = 'calls')", [repo])
    }

    /// Replaces the derived nodes of `kinds` (and their edges) for a repository.
    func replaceDerived(repo: String, kinds: [String], nodes: [KnowledgeNode], edges: [KnowledgeEdge]) throws {
        try transaction {
            for kind in kinds {
                try run("DELETE FROM edges WHERE src IN (SELECT id FROM nodes WHERE repo = ?1 AND kind = ?2) OR dst IN (SELECT id FROM nodes WHERE repo = ?1 AND kind = ?2)", [repo, kind])
                try run("DELETE FROM nodes WHERE repo = ?1 AND kind = ?2", [repo, kind])
            }
            try upsert(nodes)
            try upsert(edges)
        }
    }

    /// A read-only SQL query over the graph (nodes, edges, symbol_calls), at most `limit` rows.
    func query(_ sql: String, limit: Int = 200) throws -> [[String: JSONValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw StoreError.sqlite("Only read-only queries (SELECT, WITH…) are allowed.") }
        var rows: [[String: JSONValue]] = []
        let columns = sqlite3_column_count(statement)
        while rows.count < limit, sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: JSONValue] = [:]
            for column in 0..<columns {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .number(Double(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row[name] = .number(sqlite3_column_double(statement, column))
                case SQLITE_NULL: row[name] = .null
                case SQLITE_BLOB: row[name] = "<blob>"
                default: row[name] = .string(text(statement, column))
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: Vectors

    func vectorHashes(repo: String) throws -> [String: String] {
        let statement = try prepare("SELECT id, hash FROM vectors WHERE repo = ?1")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0)] = text(statement, 1) }
        return result
    }

    func setVectors(repo: String, _ vectors: [(id: String, hash: String, vector: [Float])], removing: [String]) throws {
        try transaction {
            for id in removing { try run("DELETE FROM vectors WHERE id = ?1", [id]) }
            let statement = try prepare("INSERT OR REPLACE INTO vectors(id, repo, hash, vector) VALUES (?1, ?2, ?3, ?4)")
            defer { sqlite3_finalize(statement) }
            for item in vectors {
                sqlite3_reset(statement)
                bind(statement, [item.id, repo, item.hash])
                _ = item.vector.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), Self.transientBlob) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error("vector") }
            }
        }
    }

    /// Every stored vector (optionally of one repository).
    func vectors(repo: String? = nil) throws -> [(id: String, vector: [Float])] {
        let statement = try prepare(repo == nil ? "SELECT id, vector FROM vectors" : "SELECT id, vector FROM vectors WHERE repo = ?1")
        defer { sqlite3_finalize(statement) }
        if let repo { bind(statement, [repo]) }
        var result: [(String, [Float])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Float>.size
            guard count > 0, let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let vector = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: count))
            result.append((text(statement, 0), vector))
        }
        return result
    }

    nonisolated static let transientBlob = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// MARK: - Per-repository pass

extension KnowledgeAnalysis {
    /// Recomputes a repository's modules, flows and vectors (after its files were indexed).
    static func analyze(repo: String, root: String, store: KnowledgeStore, vectors: Bool = true) async throws {
        // Modules: files grouped by how they import, call and change together.
        let relations = try await store.fileRelations(repo: repo)
        let groups = clusters(relations)
        var clusterNodes: [KnowledgeNode] = [], clusterEdges: [KnowledgeEdge] = []
        for (group, paths) in Dictionary(grouping: groups.keys, by: { groups[$0]! }) where paths.count >= 2 {
            let id = "cluster:\(root)#\(group)"
            clusterNodes.append(KnowledgeNode(id: id, kind: "cluster", name: name(of: paths), qualified: name(of: paths), repo: repo,
                                              signature: "\(paths.count) files", source: source))
            for path in paths { clusterEdges.append(KnowledgeEdge(src: "file:\(root)/\(path)", dst: id, kind: "member_of", source: source)) }
        }

        // Flows: what each entry point sets in motion.
        let calls = try await store.callGraph(repo: repo)
        let entries = try await store.uncalledSymbols(repo: repo)
            .filter { isEntryPoint(name: $0.name, signature: $0.signature, path: $0.path) && !(calls[$0.id] ?? []).isEmpty }
            .prefix(80)
        let names = Dictionary(uniqueKeysWithValues: try await store.nodes(kind: "symbol", repo: repo, limit: 200_000).map { ($0.id, $0.name) })
        var flowNodes: [KnowledgeNode] = [], flowEdges: [KnowledgeEdge] = []
        for entry in entries {
            let steps = flow(from: entry.id) { calls[$0] ?? [] }
            guard steps.count > 1 else { continue }
            let id = "flow:" + entry.id
            flowNodes.append(KnowledgeNode(id: id, kind: "flow", name: entry.name, qualified: entry.qualified, repo: repo, path: entry.path,
                                           signature: steps.prefix(8).compactMap { names[$0] }.joined(separator: " → "), source: source))
            for (order, step) in steps.enumerated() {
                flowEdges.append(KnowledgeEdge(src: id, dst: step, kind: "step", weight: Double(order), source: source))
            }
        }
        try await store.replaceDerived(repo: repo, kinds: ["cluster", "flow"], nodes: clusterNodes + flowNodes, edges: clusterEdges + flowEdges)
        if vectors { try await embed(repo: repo, store: store) }
        try await store.setMeta("analysis-v1:" + repo, ISO8601DateFormatter().string(from: .now))
    }

    /// Vectors for files, directories, types and top-level functions whose text changed.
    static func embed(repo: String, store: KnowledgeStore) async throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else { return }
        let known = try await store.vectorHashes(repo: repo)
        var wanted: [(KnowledgeNode, String)] = []
        for kind in ["directory", "file", "symbol", "cluster"] {
            for node in try await store.nodes(kind: kind, repo: repo, limit: 30_000) {
                if kind == "symbol", !["type", "class", "struct", "protocol", "interface", "enum", "function", "trait"].contains(node.language) { continue }
                let text = [words(node.qualified.isEmpty ? node.name : node.qualified), words(node.path), node.summary, String(node.signature.prefix(200))]
                    .filter { !$0.isEmpty }.joined(separator: ". ")
                wanted.append((node, text))
            }
        }
        let ids = Set(wanted.map(\.0.id))
        var fresh: [(id: String, hash: String, vector: [Float])] = []
        for (node, text) in wanted {
            let hash = stableHash(text)
            guard known[node.id] != hash, let vector = embedText(text) else { continue }
            fresh.append((node.id, hash, vector))
            if fresh.count >= 500 {
                try await store.setVectors(repo: repo, fresh, removing: [])
                fresh.removeAll()
            }
        }
        try await store.setVectors(repo: repo, fresh, removing: known.keys.filter { !ids.contains($0) })
    }

    /// FNV-1a: stable across launches (unlike `hashValue`), so unchanged text keeps its vector.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 36)
    }

    private static func embedText(_ text: String) -> [Float]? { embed(String(text.prefix(600))) }
}

extension KnowledgeStore {
    /// caller → (callee, confidence) for a repository.
    func callGraph(repo: String) throws -> [String: [(String, Double)]] {
        let statement = try prepare("SELECT e.src, e.dst, e.weight FROM edges e JOIN nodes n ON n.id = e.src WHERE n.repo = ?1 AND e.kind = 'calls'")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        var result: [String: [(String, Double)]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0), default: []].append((text(statement, 1), sqlite3_column_double(statement, 2))) }
        return result
    }
}
