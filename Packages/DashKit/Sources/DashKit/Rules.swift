import Foundation

/// One rule Dashii follows when an extension's tools or AI tasks run. Users see rules as a list
/// they toggle, edit and add to, not as text; plugins declare them with `RuleSet`'s builder.
public struct Rule: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// "Always cite PRs as owner/name#123."
        case always
        /// "Never post to GitHub."
        case never
        /// "Prefer the Datadog tools over the API."
        case prefer
        /// Context Dashii should know ("review_verdict comes from Dash's own review").
        case note

        public var title: String {
            switch self {
            case .always: "Always"
            case .never: "Never"
            case .prefer: "Prefer"
            case .note: "Note"
            }
        }

        public var systemImage: String {
            switch self {
            case .always: "checkmark.circle"
            case .never: "nosign"
            case .prefer: "hand.thumbsup"
            case .note: "info.circle"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    public var enabled: Bool

    public init(_ kind: Kind = .note, _ text: String, enabled: Bool = true, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.enabled = enabled
    }

    public static func always(_ text: String) -> Rule { Rule(.always, text) }
    public static func never(_ text: String) -> Rule { Rule(.never, text) }
    public static func prefer(_ text: String) -> Rule { Rule(.prefer, text) }
    public static func note(_ text: String) -> Rule { Rule(.note, text) }

    /// Turned off: kept in the list, not sent to Dashii.
    public func disabled() -> Rule {
        var copy = self
        copy.enabled = false
        return copy
    }

    /// What Dashii reads: "Never: post to GitHub." (notes have no prefix).
    var sentence: String { (kind == .note ? "" : "\(kind.title): ") + text }
}

@resultBuilder
public enum RuleBuilder {
    public static func buildExpression(_ rule: Rule) -> [Rule] { [rule] }
    public static func buildExpression(_ rules: [Rule]) -> [Rule] { rules }
    public static func buildBlock(_ parts: [Rule]...) -> [Rule] { parts.flatMap { $0 } }
    public static func buildOptional(_ rules: [Rule]?) -> [Rule] { rules ?? [] }
    public static func buildEither(first rules: [Rule]) -> [Rule] { rules }
    public static func buildEither(second rules: [Rule]) -> [Rule] { rules }
    public static func buildArray(_ parts: [[Rule]]) -> [Rule] { parts.flatMap { $0 } }
}

/// An extension's rules, declared fluently:
///
///     var rules: RuleSet {
///         RuleSet {
///             Rule.note("review_verdict and risk come from Dash's own review, not the team's.")
///             Rule.never("Post reviews or comments to GitHub; creating or merging a PR is the user's.")
///             Rule.always("Cite PRs as owner/name#123 with their link.")
///         }
///     }
///
/// Or shipped as Markdown in Rules/<id>.md (one `- ` line per rule, `Always:`/`Never:`/`Prefer:`
/// prefixes optional), which the default `rules` reads. Users edit them as a list in Dash.
public struct RuleSet: Sendable, Hashable, Codable {
    public var rules: [Rule]

    public init(_ rules: [Rule] = []) { self.rules = rules }
    public init(@RuleBuilder _ build: () -> [Rule]) { rules = build() }

    public var isEmpty: Bool { rules.isEmpty }

    /// What Dashii reads: the enabled rules, one line each; nil when none is on.
    public var instructions: String? {
        let lines = rules.filter { $0.enabled && !$0.text.isEmpty }.map { "- " + $0.sentence }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Stored form: every rule, disabled ones marked `- [off] `, so toggling never loses a rule.
    public var markdown: String {
        rules.filter { !$0.text.isEmpty }.map { "- " + ($0.enabled ? "" : "[off] ") + $0.sentence }.joined(separator: "\n")
    }

    /// Reads `- ` lines (or plain lines) back into rules; continuation lines join the rule above.
    public static func parse(_ text: String) -> RuleSet {
        var rules: [Rule] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let isItem = line.hasPrefix("- ") || line.hasPrefix("* ")
            if !isItem, var last = rules.popLast() {
                last.text += " " + line
                rules.append(last)
                continue
            }
            if isItem { line = String(line.dropFirst(2)) }
            var enabled = true
            if line.hasPrefix("[off] ") {
                enabled = false
                line = String(line.dropFirst(6))
            }
            var kind = Rule.Kind.note
            for candidate in [Rule.Kind.always, .never, .prefer] where line.lowercased().hasPrefix(candidate.rawValue + ":") {
                kind = candidate
                line = String(line.dropFirst(candidate.rawValue.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            rules.append(Rule(kind, line, enabled: enabled))
        }
        return RuleSet(rules)
    }
}
