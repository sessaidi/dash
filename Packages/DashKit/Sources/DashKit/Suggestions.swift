import Foundation

/// Something an extension proposes on the Home page: "3 PRs wait for your review",
/// "Agent on PROJ-12 is waiting for you". Clicking it asks Claude (`prompt`), opens `link`,
/// or opens the extension's settings when neither is set.
public struct Suggestion: Identifiable, Hashable, Sendable {
    public enum Priority: Int, Comparable, Sendable {
        case low, normal, high, urgent
        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: String
    public let title: String
    public let detail: String?
    /// SF Symbol.
    public let icon: String
    public let priority: Priority
    /// Sent to the chat when clicked.
    public let prompt: String?
    /// Opened when clicked (and there's no prompt).
    public let link: URL?
    /// The extension that proposed it (set by Dash).
    public var source: String?
    /// What it's about, listed when the card is opened (tickets, PRs, pods…).
    public var items: [Item] = []

    /// One thing a suggestion is about.
    public struct Item: Hashable, Sendable {
        public let title: String
        public let subtitle: String?
        public let link: URL?

        public init(title: String, subtitle: String? = nil, link: URL? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.link = link
        }
    }

    public init(id: String, title: String, detail: String? = nil, icon: String = "sparkles", priority: Priority = .normal,
                prompt: String? = nil, link: URL? = nil, source: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.icon = icon
        self.priority = priority
        self.prompt = prompt
        self.link = link
        self.source = source
    }

    public init(id: String, title: String, detail: String? = nil, icon: String = "sparkles", priority: Priority = .normal,
                prompt: String? = nil, link: URL? = nil, items: [Item], source: String? = nil) {
        self.init(id: id, title: title, detail: detail, icon: icon, priority: priority, prompt: prompt, link: link, source: source)
        self.items = items
    }
}
