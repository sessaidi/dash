import Foundation
import SQLite3

/// The repository-wide pass after indexing: turns the refs extractors left (names to resolve once
/// every file is in) into edges, and drops shared nodes nothing links to any more. Cheap: it reads
/// the refs and a name index, never the files. Its edges are replaced wholesale per repository.
enum ExtractionLinks {
    static let source = "code-links"
    /// Refs whose names are folders of the repository ("" is its root); the others name functions.
    static let pathKinds: Set<String> = ["runs"]

    static func link(repo: String, store: KnowledgeStore, sharedKinds: [String] = CodeExtractors.all.flatMap(\.sharedKinds)) async throws {
        let root = String(repo.dropFirst(5))
        var edges: [KnowledgeEdge] = []
        let refs = try await store.refs(repo: repo)
        if !refs.isEmpty {
            let callables = try await store.callableIndex(repo: repo)
            let directories = Set(try await store.nodes(kind: "directory", repo: repo, limit: 100_000).map(\.path))
            for (file, ref) in refs {
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
        try await store.replaceLinks(repo: repo, edges)
        try await store.pruneShared(kinds: sharedKinds)
    }

    /// Edges from a ref to the functions its names stand for: the first name that resolves wins,
    /// weighted like calls (0.95 same file, 0.85 a type or package the name points at, 0.7 same
    /// directory, 0.6 the only one, 0.3 split between up to three).
    static func resolve(_ ref: KnowledgeRef, file: String, root: String, index: [String: [String]]) -> [KnowledgeEdge] {
        let path = String(file.dropFirst(("file:" + root + "/").count))
        let directory = (path as NSString).deletingLastPathComponent
        for candidate in ref.names {
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
