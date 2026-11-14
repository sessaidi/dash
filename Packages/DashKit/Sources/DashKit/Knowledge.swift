import Foundation

/// Something an extension knows about, handed to Dash's knowledge graph so Claude can connect
/// it with the code and with what other extensions know: a ticket, a PR, an agent session,
/// a meeting. Built from data the extension already stored (no network calls).
///
/// Ids are "<kind>:<key>", e.g. "ticket:PROJ-12", "pr:acme/api#3", "person:ada@example.com".
/// Dash also links entities on its own: ticket keys mentioned in `title` or `text` become
/// `mentions` edges to "ticket:KEY".
public struct KnowledgeEntity: Sendable, Hashable, Identifiable {
    public let id: String
    /// ticket, pr, agent, meeting, person, doc…
    public let kind: String
    public let title: String
    /// Body, description or summary: searchable, and scanned for ticket keys.
    public let text: String
    public let url: URL?
    public let updated: Date?
    public let links: [KnowledgeLink]

    public init(id: String, kind: String, title: String, text: String = "", url: URL? = nil, updated: Date? = nil,
                links: [KnowledgeLink] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.url = url
        self.updated = updated
        self.links = links
    }
}

/// A typed edge from an entity. `to` is another entity's id, or one of the code graph's:
/// - "repo:owner/name": the local clone whose git remote is that repository;
/// - "repofile:owner/name:path/in/repo.swift": that file in the local clone;
/// - "ticket:KEY", "pr:owner/name#12", "person:email-or-login".
public struct KnowledgeLink: Sendable, Hashable {
    public let to: String
    /// implements, touches, mentions, works_on, authored, reviews, in_repo…
    public let kind: String

    public init(to: String, kind: String) {
        self.to = to
        self.kind = kind
    }
}
