import DashKit
import Foundation
import SwiftData

/// Rules and commands, kept in the store, with the extensions' defaults underneath.
@MainActor
final class AutomationStore {
    static let shared = AutomationStore()
    /// Set by the host at launch.
    weak var host: ExtensionHost?

    private var context: ModelContext? { host?.context }

    // MARK: Rules

    func rule(_ scope: String) -> AutomationRule? {
        try? context?.fetch(FetchDescriptor<AutomationRule>(predicate: #Predicate { $0.scope == scope })).first
    }

    /// The rules in force for a scope, as Dashii reads them: the user's list (if on), else the
    /// extension's own. Rules turned off in the list aren't sent.
    func rules(_ scope: String) -> String? {
        if let saved = rule(scope) { return saved.enabled ? RuleSet.parse(saved.text).instructions : nil }
        return shippedRules(scope).instructions
    }

    /// An extension's own rules (none for global).
    func shippedRules(_ scope: String) -> RuleSet {
        scope == "global" ? RuleSet() : host?.extensions.first { $0.id == scope }?.rules ?? RuleSet()
    }

    /// The list the user edits: their version, else the extension's own.
    func ruleSet(_ scope: String) -> RuleSet {
        rule(scope).map { RuleSet.parse($0.text) } ?? shippedRules(scope)
    }

    func setRules(_ scope: String, text: String, enabled: Bool = true) {
        guard let context else { return }
        if let existing = rule(scope) {
            existing.text = text
            existing.enabled = enabled
            existing.updatedAt = .now
        } else {
            context.insert(AutomationRule(scope: scope, text: text, enabled: enabled))
        }
        try? context.save()
        host?.activity.emit("automation.rules", source: "automation", title: "Updated rules for \(scope == "global" ? "everything" : scope)")
    }

    /// Back to the extension's default (or none, for global).
    func resetRules(_ scope: String) {
        guard let context, let existing = rule(scope) else { return }
        context.delete(existing)
        try? context.save()
    }

    /// What's added to Claude's instructions: the global rules, then each listed extension's.
    func instructions(for extensionIDs: [String]) -> String? {
        var parts: [String] = []
        if let global = rules("global") { parts.append("## The user's rules\n\(global)") }
        for id in extensionIDs {
            guard let text = rules(id) else { continue }
            let name = host?.extensions.first { $0.id == id }?.name ?? id
            parts.append("## Rules for \(name)\n\(text)")
        }
        return parts.isEmpty ? nil : "Follow these rules from the user:\n\n" + parts.joined(separator: "\n\n")
    }

    /// For a plugin's AI call attributed "extension.<id>/<task>": that extension's rules.
    func instructions(forSource source: String?) -> String? {
        guard let source, source.hasPrefix("extension.") else { return instructions(for: []) }
        let id = String(source.dropFirst("extension.".count).prefix { $0 != "/" })
        return instructions(for: [id])
    }

    // MARK: Commands

    struct Command: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let summary: String
        let prompt: String
        /// The extension that offers it (nil: made by the user).
        let scope: String?
        /// Saved in the store (user-made or customized).
        let isCustom: Bool
    }

    /// Every enabled command: the user's, then extensions' defaults they haven't customized.
    var commands: [Command] {
        let saved = (try? context?.fetch(FetchDescriptor<AutomationCommand>(sortBy: [SortDescriptor(\.name)]))) ?? []
        var result = saved.filter(\.enabled).map { Command(name: $0.name, summary: $0.summary, prompt: $0.prompt, scope: $0.scope, isCustom: true) }
        let names = Set(saved.map(\.name))
        for item in host?.extensions ?? [] where host?.isEnabled(item) == true {
            for command in item.defaultCommands where !names.contains(command.name) {
                result.append(Command(name: command.name, summary: command.summary, prompt: command.prompt, scope: item.id, isCustom: false))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    func savedCommand(_ name: String) -> AutomationCommand? {
        try? context?.fetch(FetchDescriptor<AutomationCommand>(predicate: #Predicate { $0.name == name })).first
    }

    func saveCommand(name: String, summary: String, prompt: String, scope: String? = nil, replacing old: String? = nil) throws {
        guard let context else { return }
        let name = Self.commandName(name)
        guard !name.isEmpty else { throw ToolError("A command needs a name.") }
        if let old, old != name, let existing = savedCommand(old) { context.delete(existing) }
        if let existing = savedCommand(name) {
            existing.summary = summary
            existing.prompt = prompt
        } else {
            context.insert(AutomationCommand(name: name, summary: summary, prompt: prompt, scope: scope))
        }
        try context.save()
    }

    func deleteCommand(_ name: String) {
        guard let context, let existing = savedCommand(name) else { return }
        context.delete(existing)
        try? context.save()
    }

    /// "/standup extra words" → the standup prompt with {{args}} = "extra words". nil when the
    /// text isn't a known command.
    func expand(_ text: String, now: Date = .now) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard let command = commands.first(where: { $0.name == name }) else { return nil }
        let arguments = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        var prompt = HookTemplate.fill(command.prompt, ["args": arguments, "date": now.formatted(date: .complete, time: .omitted)])
        if !arguments.isEmpty, !command.prompt.contains("{{args}}") { prompt += "\n\n\(arguments)" }
        return prompt
    }

    static func commandName(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

/// `{{name}}` and `{{event.title}}` placeholders.
enum HookTemplate {
    static func fill(_ text: String, _ values: [String: String]) -> String {
        text.replacing(/\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}/) { values[String($0.output.1)] ?? "" }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
