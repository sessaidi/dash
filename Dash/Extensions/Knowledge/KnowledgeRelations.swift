import DashKit
import Foundation

/// How the Knowledge page presents a node: its relations grouped into sections (what it exposes,
/// who calls it, what it calls, the data it reads and writes, how it runs, who owns it, its docs,
/// its tests, then the rest), a README's opening paragraph, and a repository's counts.
enum KnowledgeRelations {
    /// Sections in display order, each with its relations (seen from the node) in order.
    static let sections: [(title: String, relations: [String])] = [
        ("Exposes", ["exposes", "exposed_by", "handles", "handled_by"]),
        ("Called by", ["called_by"]),
        ("Calls", ["calls", "calls_endpoint", "calls_host", "calls_rpc", "implements", "implemented_by"]),
        ("Reads & writes", ["reads_table", "writes_table", "migrates", "read_by", "written_by", "migrated_by", "publishes", "consumes",
                            "published_by", "consumed_by", "checks_flag", "checked_by", "reads_config", "sets_config", "reads_env", "sets_env", "set_by"]),
        ("Runs as", ["runs", "run_by", "deploys", "deployed_by", "uses_image", "used_by"]),
        ("Owned by", ["owned_by", "owns"]),
        ("Documented in", ["documented_by", "documented_in"]),
        ("Tests", ["tested_by", "tests"]),
    ]

    struct Group: Equatable {
        /// The section's title, empty for relations outside the sections.
        var section: String
        var relation: String
        var nodes: [KnowledgeNode]
        var title: String { relation.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    /// A node's neighbours as relation groups: the sections' first, in order, then the others by name.
    static func groups(_ neighbors: [KnowledgeNeighbor]) -> [Group] {
        var byRelation: [String: [KnowledgeNode]] = [:]
        var order: [String] = []
        for neighbor in neighbors {
            let relation = neighbor.incoming ? KnowledgeExtension.inverse(neighbor.edge.kind) : neighbor.edge.kind
            if byRelation[relation] == nil { order.append(relation) }
            if byRelation[relation]?.contains(neighbor.node) != true { byRelation[relation, default: []].append(neighbor.node) }
        }
        var result: [Group] = []
        for section in sections {
            for relation in section.relations {
                if let nodes = byRelation.removeValue(forKey: relation) { result.append(Group(section: section.title, relation: relation, nodes: nodes)) }
            }
        }
        result += byRelation.keys.sorted().map { Group(section: "", relation: $0, nodes: byRelation[$0] ?? []) }
        return result
    }

    /// The first paragraph of prose in a document: no title, heading, badge, image, HTML, table,
    /// list or code block. Lines of the paragraph joined by spaces, at most 600 characters.
    static func firstParagraph(_ text: String) -> String {
        var paragraph: [String] = []
        var fence = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle(); if !paragraph.isEmpty { break }; continue }
            if fence { continue }
            if line.isEmpty { if paragraph.isEmpty { continue } else { break } }
            if paragraph.count == 1, line.count >= 3, line.allSatisfy({ "=-~^*#".contains($0) }) { paragraph = []; continue }
            let skipped = ["#", "=", "![", "[![", "<", "|", "- ", "* ", "+ ", ">", "---", ":", ".."].contains { line.hasPrefix($0) }
                || line.allSatisfy { "=-~^*#".contains($0) }
            if skipped { if paragraph.isEmpty { continue } else { break } }
            paragraph.append(line)
        }
        let joined = paragraph.joined(separator: " ")
        return joined.count > 600 ? String(joined.prefix(599)) + "…" : joined
    }

    /// "1 service · 2 endpoints · 1 topic".
    static func statsLine(_ stats: [(kind: String, count: Int)]) -> String {
        stats.map { "\($0.count) \($0.kind)\($0.count == 1 ? "" : "s")" }.joined(separator: " · ")
    }
}

extension KnowledgeExtension {
    /// The README documenting a directory or repository, with its opening paragraph.
    func readme(of node: KnowledgeNode) async -> (doc: KnowledgeNode, paragraph: String)? {
        guard let store, node.kind == "directory" || node.kind == "repo" else { return nil }
        let docs = ((try? await store.neighbors(node.id, kinds: ["documents"], limit: 50)) ?? []).filter(\.incoming).map(\.node)
        guard let doc = docs.first(where: { ($0.path as NSString).lastPathComponent.uppercased().hasPrefix("README") }) else { return nil }
        let paragraph = KnowledgeRelations.firstParagraph(doc.signature)
        return paragraph.isEmpty ? nil : (doc, paragraph)
    }
}

extension KnowledgeStore {
    /// How many services, endpoints, topics, tables, workloads and code owners a repository has
    /// (the kinds with none left out).
    func stats(repo: String) throws -> [(kind: String, count: Int)] {
        let queries: [(String, String)] = [
            ("service", "SELECT count(*) FROM nodes WHERE kind = 'service' AND repo = ?1"),
            ("endpoint", """
                SELECT count(DISTINCT e.src) FROM edges e JOIN nodes f ON f.id = e.dst
                WHERE e.kind = 'defined_in' AND e.src >= 'endpoint:' AND e.src < 'endpoint;' AND f.repo = ?1
                """),
            ("topic", """
                SELECT count(DISTINCT e.dst) FROM edges e JOIN nodes s ON s.id = e.src
                WHERE e.kind IN ('publishes', 'consumes') AND e.dst >= 'topic:' AND e.dst < 'topic;' AND s.repo = ?1
                """),
            ("table", """
                SELECT count(*) FROM (
                  SELECT e.dst FROM edges e JOIN nodes s ON s.id = e.src WHERE e.kind IN ('migrates', 'reads_table', 'writes_table') AND s.repo = ?1
                  UNION SELECT e.src FROM edges e JOIN nodes f ON f.id = e.dst WHERE e.kind = 'defined_in' AND e.src >= 'table:' AND e.src < 'table;' AND f.repo = ?1)
                """),
            ("workload", "SELECT count(*) FROM nodes WHERE kind = 'workload' AND repo = ?1"),
            ("owner", """
                SELECT count(DISTINCT e.src) FROM edges e JOIN nodes n ON n.id = e.dst
                WHERE e.kind = 'owns' AND e.src >= 'owner:' AND e.src < 'owner;' AND (n.repo = ?1 OR n.id = ?1)
                """),
        ]
        return try queries.compactMap { kind, sql in
            let count = Int(try strings("SELECT CAST((\(sql)) AS TEXT)", [repo]).first ?? "") ?? 0
            return count > 0 ? (kind, count) : nil
        }
    }
}
