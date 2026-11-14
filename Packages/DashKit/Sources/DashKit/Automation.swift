import Foundation

/// An activity event an extension emits, declared so users can build hooks on it
/// ("when `pr.review_requested` happens, …").
public struct EventDefinition: Sendable, Hashable {
    /// The `kind` passed to `activity.emit`, e.g. "pr.review_requested".
    public let kind: String
    public let summary: String

    public init(_ kind: String, _ summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

/// A reusable prompt the user runs as `/name arguments` in the chat or the Home ask bar.
/// `{{args}}` in the prompt is replaced by what follows the name; `{{date}}` by today.
public struct CommandDefinition: Sendable, Hashable {
    public let name: String
    public let summary: String
    public let prompt: String

    public init(name: String, summary: String, prompt: String) {
        self.name = name
        self.summary = summary
        self.prompt = prompt
    }
}
