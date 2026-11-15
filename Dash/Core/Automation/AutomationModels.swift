import Foundation
import SwiftData

/// The user's rules for Claude: "global" (every conversation) or one extension's id (whenever
/// that extension's tools or AI tasks are used).
@Model
final class AutomationRule {
    @Attribute(.unique) var scope: String
    var text: String
    var enabled: Bool
    var updatedAt: Date

    init(scope: String, text: String, enabled: Bool = true) {
        self.scope = scope
        self.text = text
        self.enabled = enabled
        updatedAt = .now
    }
}

/// A `/command`: a named prompt with `{{args}}`. User-made, or a customized plugin default.
@Model
final class AutomationCommand {
    @Attribute(.unique) var name: String
    var summary: String
    var prompt: String
    var enabled: Bool
    /// The extension whose default this customizes, if any.
    var scope: String?

    init(name: String, summary: String, prompt: String, scope: String? = nil, enabled: Bool = true) {
        self.name = name
        self.summary = summary
        self.prompt = prompt
        self.scope = scope
        self.enabled = enabled
    }
}

/// "When this happens, do that." The trigger and action are stored as JSON.
@Model
final class AutomationHook {
    @Attribute(.unique) var id: UUID
    var name: String
    var enabled: Bool
    var triggerData: Data
    var actionData: Data
    var createdAt: Date
    var lastRun: Date?
    var lastStatus: String?

    init(name: String, trigger: HookTrigger, action: HookAction, enabled: Bool = true) {
        id = UUID()
        self.name = name
        self.enabled = enabled
        triggerData = (try? JSONEncoder().encode(trigger)) ?? Data()
        actionData = (try? JSONEncoder().encode(action)) ?? Data()
        createdAt = .now
    }

    var trigger: HookTrigger {
        get { (try? JSONDecoder().decode(HookTrigger.self, from: triggerData)) ?? .launch }
        set { triggerData = (try? JSONEncoder().encode(newValue)) ?? triggerData }
    }

    var action: HookAction {
        get { (try? JSONDecoder().decode(HookAction.self, from: actionData)) ?? .notify(title: name, body: "") }
        set { actionData = (try? JSONEncoder().encode(newValue)) ?? actionData }
    }
}

/// One run of a hook, kept for the history in Settings.
@Model
final class HookRun {
    var date: Date
    var hookID: UUID
    var hookName: String
    var succeeded: Bool
    var output: String

    init(hook: AutomationHook, succeeded: Bool, output: String) {
        date = .now
        hookID = hook.id
        hookName = hook.name
        self.succeeded = succeeded
        self.output = String(output.prefix(4000))
    }
}

/// What starts a hook.
enum HookTrigger: Codable, Hashable {
    /// An activity event. `kind` may end with `*` ("pr.*"); `contains` filters on its title or detail.
    case event(kind: String, source: String?, contains: String?, criticalOnly: Bool)
    /// Every chosen weekday (1 = Sunday … 7 = Saturday) at "HH:mm".
    case schedule(time: String, weekdays: [Int])
    /// When Dash starts.
    case launch
    /// Before Claude runs a tool (the action may require approval or block it).
    case beforeTool(name: String)
    /// After Claude ran a tool.
    case afterTool(name: String)
    /// A watcher: every `everyMinutes`, Dash runs this DashQL query itself (no Claude) and fires
    /// when rows appear that weren't there last time, told apart by `key` (a field) or the whole row.
    case query(query: String, everyMinutes: Int, key: String?)

    var summary: String {
        switch self {
        case .event(let kind, let source, let contains, let criticalOnly):
            "When \(kind)\(source.map { " from \($0)" } ?? "")\(contains.map { " mentions “\($0)”" } ?? "")\(criticalOnly ? " (critical)" : "")"
        case .schedule(let time, let weekdays):
            "At \(time) on \(weekdays.count == 7 ? "every day" : weekdays.sorted() == [2, 3, 4, 5, 6] ? "weekdays" : weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[($0 - 1) % 7] }.joined(separator: ", "))"
        case .launch: "When Dash starts"
        case .beforeTool(let name): "Before Dashii runs \(name)"
        case .afterTool(let name): "After Dashii ran \(name)"
        case .query(let query, let minutes, _): "When `\(query.count > 60 ? String(query.prefix(60)) + "…" : query)` finds something new (every \(minutes) min)"
        }
    }
}

/// What a hook does. Text fields take `{{event.title}}`, `{{date}}`, `{{tool.input}}`… values.
enum HookAction: Codable, Hashable {
    /// Ask Claude; optionally save the answer as a note and/or notify.
    case prompt(prompt: String, noteTitle: String?, notify: Bool)
    /// Run a `/command` with arguments, like `prompt`.
    case command(name: String, arguments: String, noteTitle: String?, notify: Bool)
    case note(title: String, folder: String?, body: String)
    case notify(title: String, body: String)
    /// Run one of Dash's tools with a JSON input.
    case tool(name: String, input: String)
    /// Wake a background agent with what the trigger found ({{rows}}…): agents run when needed,
    /// not on a timer. `id` is the agent's id (Settings › Automation › Agents).
    case agent(id: String, context: String)
    /// A shell command; asks every time before running.
    case shell(command: String)
    /// Before a tool: ask the user first.
    case requireApproval(message: String)
    /// Before a tool: refuse it, telling Claude why.
    case block(message: String)

    var summary: String {
        switch self {
        case .prompt: "Ask Dashii"
        case .command(let name, _, _, _): "Run /\(name)"
        case .note(let title, _, _): "Create note “\(title)”"
        case .notify: "Notify me"
        case .tool(let name, _): "Run \(name)"
        case .agent(let id, _): id.isEmpty ? "Wake an agent (pick one)" : "Wake agent \(id)"
        case .shell: "Run a shell command"
        case .requireApproval: "Ask me first"
        case .block: "Block it"
        }
    }
}
