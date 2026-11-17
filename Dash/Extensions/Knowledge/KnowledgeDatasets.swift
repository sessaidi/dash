import DashKit
import Foundation

/// DashQL datasets over what extraction found in code: endpoints, topics, tables, flags and code
/// owners, one SQL query each over the graph. Repositories are given by name; lists are names of
/// symbols ("Type.method") or file paths.
extension KnowledgeExtension {
    var datasets: [QueryDataset] {
        [
            QueryDataset(name: "endpoints", aliases: ["routes"],
                         summary: "HTTP routes the indexed code defines, one row per defining file: handler, services exposing it, callers and tests from any repository.",
                         fields: [.init("method"), .init("path", "string", "Parameters as {}: /invoices/{}"), .init("repo"), .init("services", "list"),
                                  .init("handler"), .init("file"), .init("line", "number"), .init("callers", "number"), .init("tests", "number")]) { [weak self] _ in
                guard let store = self?.store else { return [] }
                return try await store.query(KnowledgeDatasets.endpoints, limit: 100_000).map(KnowledgeDatasets.endpoint)
            },
            QueryDataset(name: "topics", aliases: ["queues"],
                         summary: "Message topics, queues and subjects (Kafka, Pub/Sub, SQS, SNS, NATS, RabbitMQ) with the code publishing and consuming them.",
                         fields: [.init("system"), .init("name"), .init("repos", "list"), .init("publishers", "list"), .init("consumers", "list")]) { [weak self] _ in
                guard let store = self?.store else { return [] }
                return try await store.query(KnowledgeDatasets.topics, limit: 100_000).map(KnowledgeDatasets.topic)
            },
            QueryDataset(name: "tables", summary: "Database tables from migrations and ORM models, with their columns and the code reading or writing them.",
                         fields: [.init("name"), .init("schema"), .init("columns", "list"), .init("repos", "list"), .init("readers", "list"),
                                  .init("writers", "list"), .init("migrations", "list")]) { [weak self] _ in
                guard let store = self?.store else { return [] }
                return try await store.query(KnowledgeDatasets.tables, limit: 100_000).map(KnowledgeDatasets.table)
            },
            QueryDataset(name: "flags", aliases: ["feature_flags"], summary: "Feature flags the code checks or defines.",
                         fields: [.init("key"), .init("system", "string", "launchdarkly, openfeature, flagd, unleash… or custom"), .init("repos", "list"),
                                  .init("checks", "list", "The functions (or files) checking it"), .init("defined_in", "list")]) { [weak self] _ in
                guard let store = self?.store else { return [] }
                return try await store.query(KnowledgeDatasets.flags, limit: 100_000).map(KnowledgeDatasets.flag)
            },
            QueryDataset(name: "owners", aliases: ["codeowners"], summary: "CODEOWNERS: one row per owner and what it owns (a repository, folder or file).",
                         fields: [.init("owner"), .init("type", "string", "team, user or email"), .init("target", "string", "repo/path"),
                                  .init("kind", "string", "repo, directory or file"), .init("repo")]) { [weak self] _ in
                guard let store = self?.store else { return [] }
                return try await store.query(KnowledgeDatasets.owners, limit: 100_000).map(KnowledgeDatasets.owner)
            },
        ]
    }
}

enum KnowledgeDatasets {
    /// How a node shows in a list: a symbol's qualified name, a file's path, else its name.
    private static let shown = "CASE s.kind WHEN 'symbol' THEN s.qualified WHEN 'file' THEN s.path ELSE s.name END"

    static let endpoints = """
        SELECT e.qualified AS route, f.repo, f.path AS file,
          (SELECT h.qualified || char(9) || h.path || char(9) || h.line FROM edges x JOIN nodes h ON h.id = x.dst
           WHERE x.src = e.id AND x.kind = 'handled_by' AND h.repo = f.repo ORDER BY h.path = f.path DESC, h.path LIMIT 1) AS handler,
          (SELECT group_concat(s.name, char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = e.id AND x.kind = 'exposes' AND s.repo = f.repo) AS services,
          (SELECT count(*) FROM edges x WHERE x.dst = e.id AND x.kind = 'calls_endpoint') AS callers,
          (SELECT count(*) FROM edges x WHERE x.dst = e.id AND x.kind = 'tests') AS tests
        FROM edges d JOIN nodes e ON e.id = d.src JOIN nodes f ON f.id = d.dst
        WHERE d.kind = 'defined_in' AND d.src >= 'endpoint:' AND d.src < 'endpoint;'
        ORDER BY f.repo, substr(e.qualified, instr(e.qualified, ' ') + 1), e.qualified
        """

    static let topics = """
        SELECT t.name, t.language AS system,
          (SELECT group_concat(\(shown), char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = t.id AND x.kind = 'publishes') AS publishers,
          (SELECT group_concat(\(shown), char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = t.id AND x.kind = 'consumes') AS consumers,
          (SELECT group_concat(s.repo, char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = t.id AND x.kind IN ('publishes', 'consumes')) AS repos
        FROM nodes t WHERE t.kind = 'topic' ORDER BY t.language, t.name
        """

    static let tables = """
        SELECT t.qualified, t.signature,
          (SELECT group_concat(\(shown), char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = t.id AND x.kind = 'reads_table') AS readers,
          (SELECT group_concat(\(shown), char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = t.id AND x.kind = 'writes_table') AS writers,
          (SELECT group_concat(s.path, char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = t.id AND x.kind = 'migrates') AS migrations,
          (SELECT group_concat(s.repo, char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = t.id AND x.kind IN ('reads_table', 'writes_table', 'migrates')) ||
            char(10) || ifnull((SELECT group_concat(s.repo, char(10)) FROM edges x JOIN nodes s ON s.id = x.dst WHERE x.src = t.id AND x.kind = 'defined_in'), '') AS repos
        FROM nodes t WHERE t.kind = 'table' ORDER BY t.qualified
        """

    static let flags = """
        SELECT g.name AS key, g.language AS system,
          (SELECT group_concat(\(shown), char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = g.id AND x.kind = 'checks_flag') AS checks,
          (SELECT group_concat(s.path, char(10)) FROM edges x JOIN nodes s ON s.id = x.dst WHERE x.src = g.id AND x.kind = 'defined_in') AS defined_in,
          ifnull((SELECT group_concat(s.repo, char(10)) FROM edges x JOIN nodes s ON s.id = x.src WHERE x.dst = g.id AND x.kind = 'checks_flag'), '') || char(10) ||
            ifnull((SELECT group_concat(s.repo, char(10)) FROM edges x JOIN nodes s ON s.id = x.dst WHERE x.src = g.id AND x.kind = 'defined_in'), '') AS repos
        FROM nodes g WHERE g.kind = 'flag' ORDER BY g.name
        """

    static let owners = """
        SELECT o.name AS owner, o.language AS type, n.kind, CASE n.kind WHEN 'repo' THEN n.id ELSE n.repo END AS repo, n.path
        FROM edges x JOIN nodes o ON o.id = x.src JOIN nodes n ON n.id = x.dst
        WHERE x.kind = 'owns' AND x.src >= 'owner:' AND x.src < 'owner;' ORDER BY o.name, repo, n.path
        """

    static func endpoint(_ row: [String: JSONValue]) -> JSONValue {
        let route = row["route"]?.string ?? ""
        let parts = route.split(separator: " ", maxSplits: 1).map(String.init)
        let handler = (row["handler"]?.string ?? "").components(separatedBy: "\t")
        let repo = row["repo"]?.string ?? ""
        return ["method": .string(parts.first ?? ""), "path": .string(parts.count > 1 ? parts[1] : ""), "repo": .string(KnowledgeExtension.repoName(repo)),
                "services": list(row["services"]), "handler": handler.count == 3 ? .string(handler[0]) : .null,
                "file": .string(handler.count == 3 ? handler[1] : row["file"]?.string ?? ""),
                "line": handler.count == 3 ? .number(Double(handler[2]) ?? 0) : .null,
                "callers": row["callers"] ?? 0, "tests": row["tests"] ?? 0]
    }

    static func topic(_ row: [String: JSONValue]) -> JSONValue {
        ["system": row["system"] ?? "", "name": row["name"] ?? "", "repos": repos(row["repos"]),
         "publishers": list(row["publishers"]), "consumers": list(row["consumers"])]
    }

    static func table(_ row: [String: JSONValue]) -> JSONValue {
        let qualified = row["qualified"]?.string ?? ""
        let parts = qualified.split(separator: ".", maxSplits: 1).map(String.init)
        return ["name": .string(parts.last ?? qualified), "schema": .string(parts.count > 1 ? parts[0] : ""),
                "columns": .array(columns(row["signature"]?.string ?? "").map { .string($0) }), "repos": repos(row["repos"]),
                "readers": list(row["readers"]), "writers": list(row["writers"]), "migrations": list(row["migrations"])]
    }

    static func flag(_ row: [String: JSONValue]) -> JSONValue {
        ["key": row["key"] ?? "", "system": row["system"] ?? "", "repos": repos(row["repos"]),
         "checks": list(row["checks"]), "defined_in": list(row["defined_in"])]
    }

    static func owner(_ row: [String: JSONValue]) -> JSONValue {
        let repo = KnowledgeExtension.repoName(row["repo"]?.string ?? "")
        let path = row["path"]?.string ?? ""
        return ["owner": row["owner"] ?? "", "type": row["type"] ?? "", "target": .string(path.isEmpty ? repo : repo + "/" + path),
                "kind": row["kind"] ?? "", "repo": .string(repo)]
    }

    /// A newline-joined column as a sorted list without duplicates.
    private static func list(_ value: JSONValue?) -> JSONValue {
        .array(Set((value?.string ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }).sorted().map { .string($0) })
    }

    private static func repos(_ value: JSONValue?) -> JSONValue {
        .array(Set((value?.string ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }.map(KnowledgeExtension.repoName)).sorted().map { .string($0) })
    }

    /// The columns a table's signature lists: "table public.invoices (id, total)".
    static func columns(_ signature: String) -> [String] {
        guard TableHistory.isLive(signature), signature.hasSuffix(")"), let open = signature.range(of: " (") else { return [] }
        return signature[open.upperBound..<signature.index(before: signature.endIndex)].components(separatedBy: ", ")
            .filter { !$0.hasPrefix("… ") }
    }
}
