import Foundation
import SQLite3

/// A node of the knowledge graph: a repository, directory, file, symbol, package, ticket, PR,
/// agent session, meeting, note, person or concept.
struct KnowledgeNode: Sendable, Hashable, Identifiable {
    var id: String
    var kind: String
    var name: String
    /// Container-qualified name for symbols ("Type.method"), "owner/name" for repositories.
    var qualified: String = ""
    /// The repository node's id for code, empty otherwise.
    var repo: String = ""
    /// Path inside the repository for directories, files and symbols.
    var path: String = ""
    var line: Int = 0
    var endLine: Int = 0
    var language: String = ""
    /// A symbol's declaration line, an entity's text.
    var signature: String = ""
    /// What Claude understood about it (directories, repositories, concepts).
    var summary: String = ""
    var url: String = ""
    /// Content hash for files (incremental indexing).
    var hash: String = ""
    /// Who wrote it: code, git, claude, or the extension id that handed it in.
    var source: String = ""
    var updated: Date = .now
    var summarized: Date?
}

struct KnowledgeEdge: Sendable, Hashable {
    var src: String
    var dst: String
    /// contains, defines, imports, calls, authored, changes_with, touches, mentions, about…
    var kind: String
    var weight: Double = 1
    var source: String = ""
}

/// An edge an extractor can't make from one file: `src` gets a `kind` edge to whatever `names`
/// (best first) turn out to be once the whole repository is indexed, such as a route's handler
/// function or the folder a service runs. Kept per file, resolved by `ExtractionLinks`.
struct KnowledgeRef: Sendable, Hashable {
    var src: String
    var kind: String
    var names: [String]
    var line: Int = 0
}

/// A neighbour seen from a node: the edge and the node at its other end.
struct KnowledgeNeighbor: Sendable, Hashable {
    var edge: KnowledgeEdge
    var node: KnowledgeNode
    /// True when the edge points at the node asked about (an incoming edge).
    var incoming: Bool
}

/// The knowledge graph's own SQLite database (full-text search over names, signatures and
/// summaries). Separate from the SwiftData store because a large repository makes hundreds of
/// thousands of rows, written in bulk off the main thread.
actor KnowledgeStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    let url: URL?

    enum StoreError: LocalizedError {
        case sqlite(String)
        var errorDescription: String? { if case .sqlite(let message) = self { message } else { nil } }
    }

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) throws {
        self.url = url
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url?.path ?? ":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.sqlite("Couldn't open the knowledge database.")
        }
        db = handle
        try Self.exec(handle, """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS nodes(
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, qualified TEXT, repo TEXT, path TEXT,
                line INTEGER, end_line INTEGER, language TEXT, signature TEXT, summary TEXT, url TEXT, hash TEXT,
                source TEXT, updated REAL, summarized REAL);
            CREATE INDEX IF NOT EXISTS nodes_kind ON nodes(kind);
            CREATE INDEX IF NOT EXISTS nodes_file ON nodes(repo, path);
            CREATE INDEX IF NOT EXISTS nodes_name ON nodes(name);
            CREATE INDEX IF NOT EXISTS nodes_qualified ON nodes(qualified);
            CREATE TABLE IF NOT EXISTS edges(
                src TEXT NOT NULL, dst TEXT NOT NULL, kind TEXT NOT NULL, weight REAL, source TEXT,
                PRIMARY KEY(src, kind, dst)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS edges_dst ON edges(dst, kind);
            CREATE INDEX IF NOT EXISTS edges_source ON edges(source);
            CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
                name, qualified, signature, summary, content='nodes', content_rowid='rowid', tokenize='unicode61');
            CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
                INSERT INTO nodes_fts(rowid, name, qualified, signature, summary)
                VALUES (new.rowid, new.name, new.qualified, new.signature, new.summary);
            END;
            CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
                INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified, signature, summary)
                VALUES ('delete', old.rowid, old.name, old.qualified, old.signature, old.summary);
            END;
            CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE ON nodes BEGIN
                INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified, signature, summary)
                VALUES ('delete', old.rowid, old.name, old.qualified, old.signature, old.summary);
                INSERT INTO nodes_fts(rowid, name, qualified, signature, summary)
                VALUES (new.rowid, new.name, new.qualified, new.signature, new.summary);
            END;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS symbol_calls(src TEXT NOT NULL, name TEXT NOT NULL, repo TEXT NOT NULL, PRIMARY KEY(src, name)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS symbol_calls_name ON symbol_calls(repo, name);
            CREATE TABLE IF NOT EXISTS vectors(id TEXT PRIMARY KEY, repo TEXT, hash TEXT, vector BLOB);
            CREATE TABLE IF NOT EXISTS refs(file TEXT NOT NULL, repo TEXT NOT NULL, src TEXT NOT NULL, kind TEXT NOT NULL, names TEXT NOT NULL, line INTEGER);
            CREATE INDEX IF NOT EXISTS refs_file ON refs(file);
            CREATE INDEX IF NOT EXISTS refs_repo ON refs(repo);
            """)
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: Writing

    /// Runs `body` in one transaction (bulk writes are much faster).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Inserts or updates nodes. An empty `summary` keeps the one already stored.
    func upsert(_ nodes: [KnowledgeNode]) throws {
        let statement = try prepare("""
            INSERT INTO nodes(id, kind, name, qualified, repo, path, line, end_line, language, signature, summary, url, hash, source, updated, summarized)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, name = excluded.name, qualified = excluded.qualified,
                repo = excluded.repo, path = excluded.path, line = excluded.line, end_line = excluded.end_line,
                language = excluded.language, signature = excluded.signature,
                summary = CASE WHEN excluded.summary = '' THEN nodes.summary ELSE excluded.summary END,
                url = excluded.url, hash = excluded.hash, source = excluded.source, updated = excluded.updated,
                summarized = COALESCE(excluded.summarized, nodes.summarized)
            """)
        defer { sqlite3_finalize(statement) }
        for node in nodes {
            sqlite3_reset(statement)
            bind(statement, [node.id, node.kind, node.name, node.qualified, node.repo, node.path, node.line, node.endLine, node.language,
                             node.signature, node.summary, node.url, node.hash, node.source, node.updated.timeIntervalSince1970,
                             node.summarized?.timeIntervalSince1970])
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error("upsert node \(node.id)") }
        }
    }

    func upsert(_ edges: [KnowledgeEdge]) throws {
        let statement = try prepare("""
            INSERT INTO edges(src, dst, kind, weight, source) VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(src, kind, dst) DO UPDATE SET weight = excluded.weight, source = excluded.source
            """)
        defer { sqlite3_finalize(statement) }
        for edge in edges where edge.src != edge.dst {
            sqlite3_reset(statement)
            bind(statement, [edge.src, edge.dst, edge.kind, edge.weight, edge.source])
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error("upsert edge") }
        }
    }

    /// Replaces a file's nodes, outgoing edges, the edges extractors filed under it and its refs.
    /// Symbols that vanished lose their incoming edges too; the ones that stay keep edges other
    /// files point at them.
    func replaceFile(repo: String, path: String, nodes: [KnowledgeNode], edges: [KnowledgeEdge], refs: [KnowledgeRef] = []) throws {
        let file = "file:" + String(repo.dropFirst(5)) + "/" + path
        let old = try strings("SELECT id FROM nodes WHERE repo = ?1 AND path = ?2 AND kind IN ('file', 'symbol', 'decision')", [repo, path])
        let kept = Set(nodes.map(\.id))
        try run("DELETE FROM edges WHERE source = ?1", [file])
        try run("DELETE FROM refs WHERE file = ?1", [file])
        for id in old {
            try run("DELETE FROM edges WHERE src = ?1 AND source = 'code'", [id])
            if !kept.contains(id) {
                try run("DELETE FROM edges WHERE dst = ?1", [id])
                try run("DELETE FROM nodes WHERE id = ?1", [id])
            }
        }
        try upsert(nodes)
        try upsert(edges)
        guard !refs.isEmpty else { return }
        let statement = try prepare("INSERT INTO refs(file, repo, src, kind, names, line) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
        defer { sqlite3_finalize(statement) }
        for ref in refs {
            sqlite3_reset(statement)
            bind(statement, [file, repo, ref.src, ref.kind, ref.names.joined(separator: "\n"), ref.line])
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error("insert ref") }
        }
    }

    struct FileGraph: Sendable {
        var path: String
        var nodes: [KnowledgeNode]
        var edges: [KnowledgeEdge]
        var refs: [KnowledgeRef] = []
    }

    /// `replaceFile` for many files in one transaction (an empty graph removes the file).
    func replaceFiles(repo: String, _ files: [FileGraph]) throws {
        guard !files.isEmpty else { return }
        try transaction {
            for file in files { try replaceFile(repo: repo, path: file.path, nodes: file.nodes, edges: file.edges, refs: file.refs) }
        }
    }

    /// A repository's refs with the file each came from.
    func refs(repo: String) throws -> [(file: String, ref: KnowledgeRef)] {
        let statement = try prepare("SELECT file, src, kind, names, line FROM refs WHERE repo = ?1")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        var result: [(String, KnowledgeRef)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), KnowledgeRef(src: text(statement, 1), kind: text(statement, 2),
                                                            names: text(statement, 3).components(separatedBy: "\n"),
                                                            line: Int(sqlite3_column_int64(statement, 4)))))
        }
        return result
    }

    /// Inserts nodes that don't exist yet, leaving existing ones alone (placeholders such as a
    /// ticket seen in a commit message, which Jira may describe better).
    func ensure(_ nodes: [KnowledgeNode]) throws {
        let statement = try prepare("""
            INSERT OR IGNORE INTO nodes(id, kind, name, qualified, repo, path, line, end_line, language, signature, summary, url, hash, source, updated, summarized)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, NULL)
            """)
        defer { sqlite3_finalize(statement) }
        for node in nodes {
            sqlite3_reset(statement)
            bind(statement, [node.id, node.kind, node.name, node.qualified, node.repo, node.path, node.line, node.endLine, node.language,
                             node.signature, node.summary, node.url, node.hash, node.source, node.updated.timeIntervalSince1970])
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error("ensure node \(node.id)") }
        }
    }

    func removeNode(_ id: String) throws {
        try run("DELETE FROM edges WHERE src = ?1 OR dst = ?1", [id])
        try run("DELETE FROM nodes WHERE id = ?1", [id])
    }

    /// Forgets a file that's gone.
    func removeFile(repo: String, path: String) throws {
        try replaceFile(repo: repo, path: path, nodes: [], edges: [])
    }

    /// Forgets everything under a repository (code, git and Claude's notes about it).
    func removeRepo(_ repo: String) throws {
        try run("DELETE FROM edges WHERE src IN (SELECT id FROM nodes WHERE repo = ?1) OR dst IN (SELECT id FROM nodes WHERE repo = ?1)", [repo])
        try run("DELETE FROM nodes WHERE repo = ?1 OR id = ?1", [repo])
        try run("DELETE FROM symbol_calls WHERE repo = ?1", [repo])
        try run("DELETE FROM vectors WHERE repo = ?1", [repo])
        // Edges extractors filed under the repository's files ("file:<root>/…"), between shared nodes too.
        let files = "file:" + String(repo.dropFirst(5)) + "/"
        try run("DELETE FROM edges WHERE source >= ?1 AND source < ?2", [files, String(files.dropLast()) + "0"])
        try run("DELETE FROM refs WHERE repo = ?1", [repo])
    }

    /// Drops the edges one writer made (e.g. "git" before re-reading history, an extension's
    /// id before re-ingesting its entities).
    func removeEdges(source: String, repo: String? = nil) throws {
        if let repo {
            try run("DELETE FROM edges WHERE source = ?1 AND (src IN (SELECT id FROM nodes WHERE repo = ?2) OR dst IN (SELECT id FROM nodes WHERE repo = ?2))", [source, repo])
        } else {
            try run("DELETE FROM edges WHERE source = ?1", [source])
        }
    }

    /// Drops nodes of `kind` written by `source` that aren't in `keep` (entities that disappeared).
    func prune(source: String, keep: Set<String>) throws {
        for id in try strings("SELECT id FROM nodes WHERE source = ?1", [source]) where !keep.contains(id) { try removeNode(id) }
    }

    func setSummary(_ id: String, _ summary: String) throws {
        try run("UPDATE nodes SET summary = ?2, summarized = ?3 WHERE id = ?1", [id, summary, Date.now.timeIntervalSince1970])
    }

    func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    func meta(_ key: String) throws -> String? {
        try strings("SELECT value FROM meta WHERE key = ?1", [key]).first
    }

    // MARK: Reading

    func node(_ id: String) throws -> KnowledgeNode? {
        try nodes("SELECT * FROM nodes WHERE id = ?1", [id]).first
    }

    func nodes(ids: [String]) throws -> [KnowledgeNode] {
        try ids.compactMap { try node($0) }
    }

    /// Nodes of one kind, optionally in one repository.
    func nodes(kind: String, repo: String? = nil, limit: Int = 500) throws -> [KnowledgeNode] {
        if let repo { return try nodes("SELECT * FROM nodes WHERE kind = ?1 AND repo = ?2 ORDER BY path LIMIT ?3", [kind, repo, limit]) }
        return try nodes("SELECT * FROM nodes WHERE kind = ?1 ORDER BY name LIMIT ?2", [kind, limit])
    }

    /// The first node whose qualified name matches (repositories by "owner/name").
    func node(qualified: String, kind: String) throws -> KnowledgeNode? {
        try nodes("SELECT * FROM nodes WHERE qualified = ?1 AND kind = ?2 LIMIT 1", [qualified, kind]).first
    }

    /// path → hash of the files indexed in a repository.
    func fileHashes(repo: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let statement = try prepare("SELECT path, hash FROM nodes WHERE repo = ?1 AND kind = 'file'")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0)] = text(statement, 1) }
        return result
    }

    // MARK: Calls

    /// The names of a file's symbols.
    func symbolNames(repo: String, path: String) throws -> [String] {
        try strings("SELECT name FROM nodes WHERE repo = ?1 AND path = ?2 AND kind = 'symbol'", [repo, path])
    }

    /// Keeps what each symbol of a file calls (by name), so callers can be resolved again later
    /// without parsing their files. `path` is the file's absolute path.
    func replaceSymbolCalls(repo: String, path: String, _ calls: [(id: String, names: [String])]) throws {
        try transaction {
            try removeSymbolCalls(repo: repo, path: path)
            let statement = try prepare("INSERT OR IGNORE INTO symbol_calls(src, name, repo) VALUES (?1, ?2, ?3)")
            defer { sqlite3_finalize(statement) }
            for (id, names) in calls {
                for name in names {
                    sqlite3_reset(statement)
                    bind(statement, [id, name, repo])
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw error("symbol_calls") }
                }
            }
        }
    }

    func removeSymbolCalls(repo: String, path: String) throws {
        try run("DELETE FROM symbol_calls WHERE repo = ?1 AND src >= ?2 AND src < ?3", [repo, "sym:" + path + "#", "sym:" + path + "$"])
    }

    /// Symbols that call any of `names`, with everything they call.
    func symbolCalls(repo: String, calling names: Set<String>) throws -> [String: [String]] {
        var callers = Set<String>()
        for chunk in Array(names).chunked(400) {
            let marks = chunk.indices.map { "?\($0 + 2)" }.joined(separator: ",")
            callers.formUnion(try strings("SELECT DISTINCT src FROM symbol_calls WHERE repo = ?1 AND name IN (\(marks))", [repo] + chunk))
        }
        var result: [String: [String]] = [:]
        for id in callers { result[id] = try strings("SELECT name FROM symbol_calls WHERE src = ?1", [id]) }
        return result
    }

    /// file id → the files and directories it imports, for a repository.
    func importTargets(repo: String) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let statement = try prepare("SELECT e.src, e.dst FROM edges e JOIN nodes n ON n.id = e.src WHERE n.repo = ?1 AND n.kind = 'file' AND e.kind = 'imports'")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0), default: []].insert(text(statement, 1)) }
        return result
    }

    /// Replaces the call edges going out of `sources`.
    func replaceCallEdges(from sources: Set<String>, _ edges: [KnowledgeEdge]) throws {
        try transaction {
            for id in sources { try run("DELETE FROM edges WHERE src = ?1 AND kind = 'calls' AND source = 'code'", [id]) }
            try upsert(edges)
        }
    }

    /// name → ids of a repository's symbols, for resolving calls by name.
    func symbolIndex(repo: String) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        let statement = try prepare("SELECT name, id FROM nodes WHERE repo = ?1 AND kind = 'symbol'")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0), default: []].append(text(statement, 1)) }
        return result
    }

    /// Full-text search over names, qualified names, signatures and summaries, best first.
    /// Exact name matches rank above everything else.
    func search(_ query: String, kinds: [String] = [], limit: Int = 30) throws -> [KnowledgeNode] {
        let terms = query.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map { "\"\($0)\"*" }
        guard !terms.isEmpty else { return [] }
        let kindFilter = kinds.isEmpty ? "" : " AND n.kind IN (\(kinds.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")))"
        let exact = try nodes("SELECT * FROM nodes n WHERE n.name = ?1\(kindFilter) LIMIT ?2", [query, limit])
        let matches = try nodes("""
            SELECT n.* FROM nodes_fts f JOIN nodes n ON n.rowid = f.rowid
            WHERE nodes_fts MATCH ?1\(kindFilter) ORDER BY bm25(nodes_fts, 10.0, 5.0, 2.0, 1.0) LIMIT ?2
            """, [terms.joined(separator: " "), limit])
        var seen = Set<String>()
        return (exact + matches).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// Edges in and out of a node, with the nodes at the other end.
    func neighbors(_ id: String, kinds: [String] = [], limit: Int = 200) throws -> [KnowledgeNeighbor] {
        let filter = kinds.isEmpty ? "" : " AND e.kind IN (\(kinds.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")))"
        var result: [KnowledgeNeighbor] = []
        for (incoming, sql) in [(false, "SELECT e.src, e.dst, e.kind, e.weight, e.source, n.* FROM edges e JOIN nodes n ON n.id = e.dst WHERE e.src = ?1\(filter) ORDER BY e.weight DESC LIMIT ?2"),
                                (true, "SELECT e.src, e.dst, e.kind, e.weight, e.source, n.* FROM edges e JOIN nodes n ON n.id = e.src WHERE e.dst = ?1\(filter) ORDER BY e.weight DESC LIMIT ?2")] {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(statement, [id, limit])
            while sqlite3_step(statement) == SQLITE_ROW {
                let edge = KnowledgeEdge(src: text(statement, 0), dst: text(statement, 1), kind: text(statement, 2),
                                         weight: sqlite3_column_double(statement, 3), source: text(statement, 4))
                result.append(KnowledgeNeighbor(edge: edge, node: readNode(statement, offset: 5), incoming: incoming))
            }
        }
        return result
    }

    /// Follows `kinds` edges (outgoing, or incoming when `reverse`) up to `depth` hops:
    /// callees, or callers with `reverse`.
    func trace(_ id: String, kinds: [String], reverse: Bool, depth: Int, minWeight: Double = 0) throws -> [(depth: Int, node: KnowledgeNode)] {
        var seen: Set<String> = [id]
        var frontier = [id]
        var result: [(Int, KnowledgeNode)] = []
        for level in 1...max(depth, 1) {
            var next: [String] = []
            for current in frontier {
                for neighbor in try neighbors(current, kinds: kinds, limit: 100)
                where neighbor.incoming == reverse && neighbor.edge.weight >= minWeight && seen.insert(neighbor.node.id).inserted {
                    result.append((level, neighbor.node))
                    next.append(neighbor.node.id)
                }
            }
            frontier = next
            if frontier.isEmpty || result.count > 300 { break }
        }
        return result
    }

    /// The shortest chain of edges (either direction) between two nodes, up to `maxDepth` hops.
    func path(from: String, to: String, maxDepth: Int = 6) throws -> [KnowledgeNeighbor]? {
        guard from != to else { return [] }
        var previous: [String: KnowledgeNeighbor] = [:]
        var frontier = [from]
        var seen: Set<String> = [from]
        for _ in 0..<maxDepth {
            var next: [String] = []
            for current in frontier {
                for neighbor in try neighbors(current, limit: 150) where seen.insert(neighbor.node.id).inserted {
                    previous[neighbor.node.id] = neighbor
                    if neighbor.node.id == to {
                        var chain: [KnowledgeNeighbor] = []
                        var cursor = to
                        while let step = previous[cursor] {
                            chain.insert(step, at: 0)
                            cursor = step.incoming ? step.edge.dst : step.edge.src
                            if cursor == from { break }
                        }
                        return chain
                    }
                    next.append(neighbor.node.id)
                }
            }
            frontier = next
            if frontier.isEmpty || seen.count > 20_000 { break }
        }
        return nil
    }

    /// Files directly inside a directory ("" is the repository root).
    func files(repo: String, directory: String) throws -> [KnowledgeNode] {
        if directory.isEmpty {
            return try nodes("SELECT * FROM nodes WHERE repo = ?1 AND kind = 'file' AND path NOT LIKE '%/%' ORDER BY path", [repo])
        }
        return try nodes("SELECT * FROM nodes WHERE repo = ?1 AND kind = 'file' AND path LIKE ?2 AND path NOT LIKE ?3 ORDER BY path",
                         [repo, directory + "/%", directory + "/%/%"])
    }

    /// Directories directly inside a directory ("" is the repository root).
    func subdirectories(repo: String, directory: String) throws -> [KnowledgeNode] {
        if directory.isEmpty {
            return try nodes("SELECT * FROM nodes WHERE repo = ?1 AND kind = 'directory' AND path NOT LIKE '%/%' ORDER BY path", [repo])
        }
        return try nodes("SELECT * FROM nodes WHERE repo = ?1 AND kind = 'directory' AND path LIKE ?2 AND path NOT LIKE ?3 ORDER BY path",
                         [repo, directory + "/%", directory + "/%/%"])
    }

    /// A file's symbols in source order.
    func symbols(repo: String, path: String) throws -> [KnowledgeNode] {
        try nodes("SELECT * FROM nodes WHERE repo = ?1 AND path = ?2 AND kind = 'symbol' ORDER BY line", [repo, path])
    }

    /// kind → count.
    /// Paths of the repositories indexed in the graph (their nodes are "repo:<path>").
    func repositoryPaths() throws -> [String] {
        var result: [String] = []
        let statement = try prepare("SELECT id FROM nodes WHERE kind = 'repo' ORDER BY id")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            if id.hasPrefix("repo:") { result.append(String(id.dropFirst(5))) }
        }
        return result
    }

    /// Who changed a file or a directory's files most (commits in the history window), most first.
    func experts(repo: String, path: String, limit: Int = 8) throws -> [(person: KnowledgeNode, commits: Int)] {
        let statement = try prepare("""
            SELECT e.src, SUM(e.weight) AS total FROM edges e JOIN nodes f ON f.id = e.dst
            WHERE e.kind = 'authored' AND f.repo = ?1 AND (?2 = '' OR f.path = ?2 OR f.path LIKE ?2 || '/%')
            GROUP BY e.src ORDER BY total DESC LIMIT ?3
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo, path, limit])
        var rows: [(String, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append((text(statement, 0), Int(sqlite3_column_double(statement, 1)))) }
        let people = Dictionary(uniqueKeysWithValues: try nodes(ids: rows.map(\.0)).map { ($0.id, $0) })
        return rows.compactMap { id, total in people[id].map { ($0, total) } }
    }

    /// How much of a repository Claude has studied: directories with a summary, of all.
    func coverage(repo: String) throws -> (studied: Int, directories: Int) {
        let statement = try prepare("SELECT COUNT(*), SUM(summary != '') FROM nodes WHERE repo = ?1 AND kind = 'directory'")
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(statement, 1)), Int(sqlite3_column_int64(statement, 0)))
    }

    /// Edges of one kind leaving or reaching nodes of a repository (e.g. its git history links).
    func edgeCount(kind: String, repo: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM edges e JOIN nodes n ON n.id = e.dst WHERE e.kind = ?1 AND n.repo = ?2")
        defer { sqlite3_finalize(statement) }
        bind(statement, [kind, repo])
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Edges per kind ("calls", "authored", …).
    func edgeCounts() throws -> [String: Int] {
        var result: [String: Int] = [:]
        let statement = try prepare("SELECT kind, COUNT(*) FROM edges GROUP BY kind")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0)] = Int(sqlite3_column_int64(statement, 1)) }
        return result
    }

    func counts() throws -> [String: Int] {
        var result: [String: Int] = [:]
        let statement = try prepare("SELECT kind, COUNT(*) FROM nodes GROUP BY kind")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0)] = Int(sqlite3_column_int64(statement, 1)) }
        result["edges"] = Int(try int("SELECT COUNT(*) FROM edges"))
        return result
    }

    /// Directories not yet understood, or changed since: the most substantial first (symbols
    /// defined under them, then how often git saw them change).
    func directoriesToUnderstand(repo: String? = nil, limit: Int) throws -> [KnowledgeNode] {
        let repoFilter = repo == nil ? "" : " AND d.repo = ?2"
        return try nodes("""
            SELECT d.* FROM nodes d
            WHERE d.kind = 'directory' AND (d.summarized IS NULL OR d.summarized < d.updated)\(repoFilter)
            ORDER BY (SELECT COUNT(*) FROM nodes s WHERE s.repo = d.repo AND s.kind = 'symbol'
                      AND (s.path LIKE d.path || '/%' OR d.path = '')) DESC
            LIMIT ?1
            """, repo.map { [limit, $0] } ?? [limit])
    }

    // MARK: SQLite plumbing

    func nodes(_ sql: String, _ values: [Any?]) throws -> [KnowledgeNode] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result: [KnowledgeNode] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(readNode(statement, offset: 0)) }
        return result
    }

    func readNode(_ statement: OpaquePointer?, offset o: Int32) -> KnowledgeNode {
        KnowledgeNode(
            id: text(statement, o), kind: text(statement, o + 1), name: text(statement, o + 2), qualified: text(statement, o + 3),
            repo: text(statement, o + 4), path: text(statement, o + 5), line: Int(sqlite3_column_int64(statement, o + 6)),
            endLine: Int(sqlite3_column_int64(statement, o + 7)), language: text(statement, o + 8), signature: text(statement, o + 9),
            summary: text(statement, o + 10), url: text(statement, o + 11), hash: text(statement, o + 12), source: text(statement, o + 13),
            updated: Date(timeIntervalSince1970: sqlite3_column_double(statement, o + 14)),
            summarized: sqlite3_column_type(statement, o + 15) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, o + 15)))
    }

    func strings(_ sql: String, _ values: [Any?]) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
        return result
    }

    func int(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
    }

    func run(_ sql: String, _ values: [Any?]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(sql) }
    }

    func exec(_ sql: String) throws { try Self.exec(db, sql) }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw StoreError.sqlite(text)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error(sql) }
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, position, number)
            default: sqlite3_bind_null(statement, position)
            }
        }
    }

    func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func error(_ context: String) -> StoreError {
        StoreError.sqlite("\(String(cString: sqlite3_errmsg(db))) (\(context.prefix(80)))")
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
