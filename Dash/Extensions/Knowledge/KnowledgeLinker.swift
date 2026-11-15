import DashKit
import Foundation

/// Brings what extensions know (tickets, PRs, agent sessions, meetings, notes) into the graph
/// and connects it to the code: explicit links from the entity, ticket keys mentioned in its
/// text, and repository/file references resolved to the local clones.
enum KnowledgeLinker {
    private static let ticketPattern = try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,6})\b"#)

    /// Jira-style keys ("PROJ-123") in a text, in order, without repeats.
    static func ticketKeys(in text: String) -> [String] {
        var seen = Set<String>()
        return ticketPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { seen.insert($0).inserted }
    }

    /// Replaces everything `source` (an extension id) handed in before with `entities`.
    static func ingest(_ entities: [KnowledgeEntity], source: String, into store: KnowledgeStore) async throws {
        var nodes: [KnowledgeNode] = []
        var edges: [KnowledgeEdge] = []
        var placeholders: [KnowledgeNode] = []
        for entity in entities {
            nodes.append(KnowledgeNode(id: entity.id, kind: entity.kind, name: entity.title, qualified: key(of: entity.id),
                                       signature: String(entity.text.prefix(entity.kind == "doc" ? 20_000 : 4000)), url: entity.url?.absoluteString ?? "",
                                       source: source, updated: entity.updated ?? .now))
            for link in entity.links {
                guard let target = try await resolve(link.to, store: store) else { continue }
                edges.append(KnowledgeEdge(src: entity.id, dst: target, kind: link.kind, source: source))
                if target.hasPrefix("ticket:") || target.hasPrefix("person:") || target.hasPrefix("pr:") {
                    placeholders.append(placeholder(target))
                }
            }
            for ticket in ticketKeys(in: entity.title + "\n" + entity.text) where "ticket:" + ticket != entity.id {
                edges.append(KnowledgeEdge(src: entity.id, dst: "ticket:" + ticket, kind: "mentions", source: source))
                placeholders.append(placeholder("ticket:" + ticket))
            }
        }
        // Placeholders first, so an entity handed in now replaces a placeholder for the same id.
        try await store.ensure(placeholders)
        try await store.removeEdges(source: source)
        try await store.upsert(nodes)
        try await store.upsert(edges)
        try await store.prune(source: source, keep: Set(nodes.map(\.id)))
    }

    /// "repo:owner/name" and "repofile:owner/name:path" become the local clone's nodes (nil
    /// when that repository isn't indexed); other ids pass through.
    static func resolve(_ id: String, store: KnowledgeStore) async throws -> String? {
        if id.hasPrefix("repo:"), !id.dropFirst(5).hasPrefix("/") {
            return try await store.node(qualified: String(id.dropFirst(5)), kind: "repo")?.id
        }
        if id.hasPrefix("repofile:") {
            let rest = id.dropFirst(9)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            guard let repo = try await store.node(qualified: String(rest[..<colon]), kind: "repo") else { return nil }
            let path = String(rest[rest.index(after: colon)...])
            let file = "file:" + String(repo.id.dropFirst(5)) + "/" + path
            return try await store.node(file) != nil ? file : nil
        }
        return id
    }

    private static func key(of id: String) -> String {
        id.firstIndex(of: ":").map { String(id[id.index(after: $0)...]) } ?? id
    }

    private static func placeholder(_ id: String) -> KnowledgeNode {
        let kind = String(id.prefix { $0 != ":" })
        return KnowledgeNode(id: id, kind: kind, name: key(of: id), qualified: key(of: id), source: "link")
    }
}

/// Builds Dash's own entities: notes (with their [[links]]).
@MainActor
enum BuiltInKnowledge {
    static func notes(_ store: NotesStore) -> [KnowledgeEntity] {
        store.notes.map { note in
            let text = store.read(note)
            let links = NotesStore.links(in: text).map { KnowledgeLink(to: "note:" + $0, kind: "links_to") }
            return KnowledgeEntity(id: "note:" + note.title, kind: "note", title: note.title, text: text,
                                   url: note.url, updated: note.modified, links: links)
        }
    }
}
