import Foundation
import SQLite3

/// The repository-wide pass after indexing: turns the refs extractors left (names to resolve once
/// every file is in) into edges, and drops shared nodes nothing links to any more. Cheap: it reads
/// the refs and a name index, never the files. Its edges are replaced wholesale per repository.
enum ExtractionLinks {
    static let source = "code-links"
    /// Refs whose names are folders of the repository ("" is its root); the others name functions.
    static let pathKinds: Set<String> = ["runs"]
    /// Refs a family's own pass resolves (workload facts, …), not names of functions.
    static let familyKinds: Set<String> = [RuntimeExtractor.factKind, ContainerExtractor.refKind, CIExtractor.refKind, ConfigKeyExtractor.refKind, OwnershipExtractor.refKind, RepoDocExtractor.refKind, DependencyExtractor.refKind, TestRequestExtractor.refKind]

    static func link(repo: String, store: KnowledgeStore, sharedKinds: [String] = CodeExtractors.all.flatMap(\.sharedKinds)) async throws {
        let root = String(repo.dropFirst(5))
        var edges: [KnowledgeEdge] = []
        let refs = try await store.refs(repo: repo)
        let deployed = try await services(repo: repo, root: root, containers: refs.filter { $0.ref.kind == ContainerExtractor.refKind }.map(\.ref), store: store)
        edges += deployed
        edges += try await WorkloadLinks.link(repo: repo, root: root, refs: refs, store: store)
        if !refs.isEmpty {
            let callables = try await store.callableIndex(repo: repo)
            let directories = Set(try await store.nodes(kind: "directory", repo: repo, limit: 100_000).map(\.path))
            let facts = refs.filter { $0.ref.kind == DatabaseExtractor.factKind }
            if !facts.isEmpty {
                let prefix = ("file:" + root + "/").count
                try await store.upsert(TableHistory.nodes(TableHistory.replay(facts.map { (String($0.file.dropFirst(prefix)), $0.ref) })))
            }
            for (file, ref) in refs where !ServiceLinks.refKinds.contains(ref.kind) && !DatabaseExtractor.refKinds.contains(ref.kind) && !familyKinds.contains(ref.kind) {
                if pathKinds.contains(ref.kind) {
                    guard let path = ref.names.first else { continue }
                    if path.isEmpty {
                        edges.append(KnowledgeEdge(src: ref.src, dst: repo, kind: ref.kind, source: source))
                    } else if directories.contains(path) {
                        edges.append(KnowledgeEdge(src: ref.src, dst: "dir:" + root + "/" + path, kind: ref.kind, source: source))
                    }
                } else {
                    edges += resolve(ref, file: file, root: root, index: callables)
                }
            }
        }
        let runs = edges.filter { $0.kind == "runs" }
        edges += try await exposes(repo: repo, root: root, services: deployed.map(\.dst), runs: runs, store: store)
        edges += try await CILinks.link(repo: repo, root: root, refs: refs.filter { $0.ref.kind == CIExtractor.refKind }.map(\.ref), runs: runs, store: store)
        edges += try await ConfigLinks.link(repo: repo, refs: refs.filter { $0.ref.kind == ConfigKeyExtractor.refKind }.map(\.ref), store: store)
        edges += try await OwnerLinks.link(repo: repo, root: root, refs: refs, store: store)
        edges += try await DocLinks.link(repo: repo, root: root, refs: refs.filter { $0.ref.kind == RepoDocExtractor.refKind }.map(\.ref), store: store)
        edges += try await TestLinks.link(repo: repo, refs: refs.filter { $0.ref.kind == TestRequestExtractor.refKind }.map(\.ref), store: store)
        try await store.replaceLinks(repo: repo, edges)
        try await store.pruneShared(kinds: sharedKinds)
        try await store.settleCalledEndpoints()
    }

    /// Services no file defines any more go; the others are deployed by the repository and say
    /// where they're defined, and what their Dockerfile exposes and runs.
    private static func services(repo: String, root: String, containers: [KnowledgeRef], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        var edges: [KnowledgeEdge] = []
        var changed: [KnowledgeNode] = []
        let facts = Dictionary(grouping: containers, by: \.src).mapValues { WorkloadLinks.Facts($0.flatMap(\.names)) }
        for service in try await store.nodes(kind: "service", repo: repo, limit: 10_000) {
            let definitions = try await store.neighbors(service.id, kinds: ["defined_in"], limit: 50).filter { !$0.incoming }.map(\.node.path).sorted()
            if definitions.isEmpty {
                try await store.removeNode(service.id)
                continue
            }
            edges.append(KnowledgeEdge(src: repo, dst: service.id, kind: "deploys", source: source))
            var node = service
            node.signature = "Defined in " + definitions.prefix(4).joined(separator: ", ") + (definitions.count > 4 ? " and \(definitions.count - 4) more" : "")
            if let container = facts[service.id] {
                if !container["port"].isEmpty { node.signature += (container["port"].count == 1 ? " · port " : " · ports ") + container["port"].joined(separator: ", ") }
                let command = (container["entrypoint"] + container["cmd"]).joined(separator: " ")
                if !command.isEmpty { node.signature += " · runs " + command }
            }
            if node.signature != service.signature { changed.append(node) }
        }
        try await store.upsert(changed)
        return edges
    }

    /// Which service serves each endpoint defined in the repository: the one whose code folder is
    /// the closest around the endpoint's file (the repository's only service otherwise).
    private static func exposes(repo: String, root: String, services: [String], runs: [KnowledgeEdge], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        guard !services.isEmpty else { return [] }
        var folders: [String: [String]] = [:]
        for edge in runs {
            folders[edge.src, default: []].append(edge.dst == repo ? "" : String(edge.dst.dropFirst(("dir:" + root + "/").count)))
        }
        var edges: [KnowledgeEdge] = []
        for (endpoint, path) in try await store.definitions(repo: repo, idPrefix: "endpoint:") {
            var best: [String] = []
            var depth = -1
            for (service, paths) in folders {
                for folder in paths where folder.isEmpty || path.hasPrefix(folder + "/") {
                    let length = folder.isEmpty ? 0 : folder.split(separator: "/").count
                    if length > depth { best = [service]; depth = length } else if length == depth, !best.contains(service) { best.append(service) }
                }
            }
            if best.isEmpty && services.count == 1 { best = services }
            edges += best.map { KnowledgeEdge(src: $0, dst: endpoint, kind: "exposes", source: source) }
        }
        return edges
    }

    /// Edges from a ref to the functions its names stand for: the first name that resolves wins,
    /// weighted like calls (0.95 same file, 0.85 a type or package the name points at, 0.7 same
    /// directory, 0.6 the only one, 0.3 split between up to three).
    static func resolve(_ ref: KnowledgeRef, file: String, root: String, index: [String: [String]]) -> [KnowledgeEdge] {
        let path = String(file.dropFirst(("file:" + root + "/").count))
        let directory = (path as NSString).deletingLastPathComponent
        for candidate in ref.names {
            // Known exactly (the decorated function, a file's exported handler).
            if candidate.hasPrefix("sym:") { return [KnowledgeEdge(src: ref.src, dst: candidate, kind: ref.kind, source: source)] }
            let parts = candidate.split(separator: ".").map(String.init)
            guard let name = parts.last, let ids = index[name], !ids.isEmpty else { continue }
            func location(_ id: String) -> String { CodeIndexer.path(ofSymbol: id, root: root) }
            // `handlers.Users.Get`: "users" names the type (or Go package) the function belongs to.
            let hint = parts.count >= 2 ? parts[parts.count - 2].lowercased() : ""
            let pointed = hint.count < 3 ? [] : ids.filter { id in
                let qualified = String(id.split(separator: "#", maxSplits: 1).last ?? "")
                let container = qualified.split(separator: ".").dropLast().joined(separator: ".").lowercased()
                let package = ((location(id) as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
                return (!container.isEmpty && (container.contains(hint) || hint.contains(container))) || package == hint
            }
            let sameFile = ids.filter { location($0) == path }
            let sameDirectory = ids.filter { (location($0) as NSString).deletingLastPathComponent == directory }
            let (targets, confidence): ([String], Double) =
                !sameFile.isEmpty ? (sameFile, 0.95)
                : (1...3).contains(pointed.count) ? (pointed, 0.85)
                : (1...3).contains(sameDirectory.count) ? (sameDirectory, 0.7)
                : ids.count == 1 ? (ids, 0.6)
                : ids.count <= 3 ? (ids, 0.3)
                : ([], 0)
            guard !targets.isEmpty else { continue }
            return targets.map { KnowledgeEdge(src: ref.src, dst: $0, kind: ref.kind, weight: confidence / Double(targets.count), source: source) }
        }
        return []
    }
}

extension KnowledgeStore {
    /// name → ids of a repository's functions and methods (what a handler name can be).
    func callableIndex(repo: String) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        let statement = try prepare("SELECT name, id FROM nodes WHERE repo = ?1 AND kind = 'symbol' AND language IN ('function', 'method')")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0), default: []].append(text(statement, 1)) }
        return result
    }

    /// Endpoints that are called but that no indexed file defines get a node of their own
    /// ("GET /users/{}"); one whose definitions all went loses its framework and handler.
    func settleCalledEndpoints() throws {
        try run("""
            INSERT OR IGNORE INTO nodes(id, kind, name, qualified, repo, path, line, end_line, language, signature, summary, url, hash, source, updated)
            SELECT DISTINCT e.dst, 'endpoint', substr(e.dst, 10), substr(e.dst, 10), '', '', 0, 0, '', substr(e.dst, 10), '', '', '', 'code', ?1
            FROM edges e WHERE e.dst >= 'endpoint:' AND e.dst < 'endpoint;' AND e.kind = 'calls_endpoint'
            AND NOT EXISTS (SELECT 1 FROM nodes n WHERE n.id = e.dst)
            """, [Date.now.timeIntervalSince1970])
        try run("""
            UPDATE nodes SET name = qualified, signature = qualified, language = ''
            WHERE kind = 'endpoint' AND (signature != qualified OR language != '')
            AND NOT EXISTS (SELECT 1 FROM edges WHERE src = nodes.id AND kind = 'defined_in')
            """, [])
    }

    /// Shared nodes whose id starts with `idPrefix` defined in a repository's files, with the file's path.
    func definitions(repo: String, idPrefix: String) throws -> [(id: String, path: String)] {
        let statement = try prepare("""
            SELECT e.src, f.path FROM edges e JOIN nodes f ON f.id = e.dst
            WHERE e.kind = 'defined_in' AND f.repo = ?1 AND f.kind = 'file' AND e.src >= ?2 AND e.src < ?3
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo, idPrefix, String(idPrefix.dropLast()) + String(UnicodeScalar(idPrefix.unicodeScalars.last!.value + 1)!)])
        var result: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append((text(statement, 0), text(statement, 1))) }
        return result
    }

    /// Replaces the link pass's edges touching a repository's nodes.
    func replaceLinks(repo: String, _ edges: [KnowledgeEdge]) throws {
        try transaction {
            try removeEdges(source: ExtractionLinks.source, repo: repo)
            try upsert(edges)
        }
    }

    /// Drops shared nodes of `kinds` (no repository) that no edge reaches or leaves.
    func pruneShared(kinds: [String]) throws {
        guard !kinds.isEmpty else { return }
        let list = kinds.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")
        try run("""
            DELETE FROM nodes WHERE kind IN (\(list)) AND repo = ''
            AND NOT EXISTS (SELECT 1 FROM edges WHERE src = nodes.id) AND NOT EXISTS (SELECT 1 FROM edges WHERE dst = nodes.id)
            """, [])
    }
}
