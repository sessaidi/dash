import DashKit
import Foundation
import SwiftData

/// The rest of the app, for Dashii: sidebar sections and page order, turning plugins on and off,
/// automation (rules, /commands, hooks), custom agents, and opening Settings screens. Anything
/// that changes the app asks the user first. Credentials and integration settings stay out of
/// reach on purpose.
@MainActor
enum AppTools {
    static func tools(host: ExtensionHost) -> [DashiiTool] {
        sidebar(host: host) + plugins(host: host) + automation(host: host) + agents(host: host) + [open(host: host)]
    }

    // MARK: Sidebar

    private static func sidebar(host: ExtensionHost) -> [DashiiTool] {
        let store = host.dashboard!
        func section(_ name: String?) throws -> UUID? {
            guard let name, !name.isEmpty, name.lowercased() != "pages" else { return nil }
            guard let found = store.sections().first(where: { $0.id.uuidString == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ToolError("No section “\(name)”. Sections: \(store.sections().map(\.name).joined(separator: ", ")).")
            }
            return found.id
        }
        func page(_ name: String) throws -> DashboardPage {
            guard let found = store.pages().first(where: { $0.id.uuidString == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ToolError("No page “\(name)”.")
            }
            return found
        }
        return [
            DashiiTool(name: "sidebar", description: "The sidebar: its sections in order, each with its pages in order (the built-in section is “Pages”), and which page shows the Home header.") { _ in
                let pages = store.pages()
                let groups: [(String?, UUID?)] = [(nil, nil)] + store.sections().map { ($0.name, $0.id) }
                return .array(groups.map { name, id in
                    ["section": .string(name ?? "Pages"), "id": id.map { .string($0.uuidString) } ?? .null,
                     "pages": .array(pages.filter { $0.sectionID == id }.sorted { $0.order < $1.order }.map {
                         ["name": .string($0.name), "id": .string($0.id.uuidString), "home": .bool($0.showsHome), "draft": .bool($0.isDraft)]
                     })]
                })
            },
            DashiiTool(name: "section_create", description: "Add a sidebar section (a group of pages).",
                       properties: ["name": JSONSchema.string("Section name.")], required: ["name"], requiresApproval: true) { input in
                guard let name = input["name"]?.string, !name.isEmpty else { throw ToolError("Name the section.") }
                let created = store.createSection(name: name)
                return ["id": .string(created.id.uuidString), "name": .string(created.name)]
            },
            DashiiTool(name: "section_rename", description: "Rename a sidebar section (“Pages” renames the built-in one).",
                       properties: ["section": JSONSchema.string("Section name or id."), "name": JSONSchema.string("New name.")],
                       required: ["section", "name"], requiresApproval: true) { input in
                guard let name = input["name"]?.string, !name.isEmpty else { throw ToolError("Give the new name.") }
                store.renameSection(try section(input["section"]?.string), to: name)
                return "renamed"
            },
            DashiiTool(name: "section_delete", description: "Delete a sidebar section; its pages move to “Pages” (nothing else is deleted).",
                       properties: ["section": JSONSchema.string("Section name or id.")], required: ["section"], requiresApproval: true) { input in
                guard let id = try section(input["section"]?.string) else { throw ToolError("The built-in “Pages” section can't be deleted.") }
                store.deleteSection(id)
                return "deleted"
            },
            DashiiTool(name: "page_move", description: "Move a page to a section (“Pages” for the built-in one), optionally before another page; or reorder within its section.",
                       properties: ["page": JSONSchema.string("Page name or id."), "section": JSONSchema.string("Target section name or id; omit to stay."),
                                    "before": JSONSchema.string("Put it before this page (name or id); omit for the end.")],
                       required: ["page"], requiresApproval: true) { input in
                let moved = try page(input["page"]?.string ?? "")
                let target = input["section"]?.string != nil ? try section(input["section"]?.string) : moved.sectionID
                let before = try input["before"]?.string.map { try page($0).id }
                store.movePage(moved.id, toSection: target, before: before)
                return "moved"
            },
            DashiiTool(name: "page_set_home", description: "Show or hide the Home header (greeting, ask bar, suggestions, brief) on a page.",
                       properties: ["page": JSONSchema.string("Page name or id."), "home": JSONSchema.boolean("true to show it.")],
                       required: ["page", "home"], requiresApproval: true) { input in
                try store.updatePage(try page(input["page"]?.string ?? "").id, showsHome: input["home"]?.bool ?? true)
                return "done"
            },
        ]
    }

    // MARK: Plugins

    private static func plugins(host: ExtensionHost) -> [DashiiTool] {
        [
            DashiiTool(name: "extensions_list", description: "Installed integrations and features: id, name, kind, version, on or off, and what they still need (integrations to connect).") { _ in
                .array(host.extensions.map { item in
                    ["id": .string(item.id), "name": .string(item.name), "kind": .string(item.layer.rawValue), "version": .string(item.metadata.version),
                     "enabled": .bool(host.isEnabled(item)), "needs": .array(host.unmetRequirements(of: item).map { .string($0) })]
                })
            },
            DashiiTool(name: "extension_set_enabled", description: "Turn an integration or feature on or off (its data and settings are kept). Connecting accounts and keys stays with the user, in Settings.",
                       properties: ["id": JSONSchema.string("Extension id from extensions_list."), "enabled": JSONSchema.boolean("true for on.")],
                       required: ["id", "enabled"], requiresApproval: true) { input in
                guard let id = input["id"]?.string, let item = host.extensions.first(where: { $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame }) else {
                    throw ToolError("No extension “\(input["id"]?.string ?? "")”.")
                }
                guard item.id != "marketplace" else { throw ToolError("The Marketplace stays on.") }
                host.setEnabled(item, input["enabled"]?.bool ?? true)
                return ["id": .string(item.id), "enabled": .bool(host.isEnabled(item))]
            },
        ]
    }

    // MARK: Automation

    private static func automation(host: ExtensionHost) -> [DashiiTool] {
        let store = AutomationStore.shared
        let context = host.context
        func hooks() -> [AutomationHook] { (try? context.fetch(FetchDescriptor<AutomationHook>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [] }
        func hook(_ id: String?) throws -> AutomationHook {
            guard let id, let found = hooks().first(where: { $0.id.uuidString == id || $0.name.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw ToolError("No hook “\(id ?? "")”. automation_list shows them.")
            }
            return found
        }
        return [
            DashiiTool(name: "automation_list", description: "The user's automation: rules for Dashii (global and per extension), /commands, and hooks (when → do), with ids.") { _ in
                let rules = ((try? context.fetch(FetchDescriptor<AutomationRule>())) ?? []).map {
                    ["scope": .string($0.scope), "text": .string($0.text), "enabled": .bool($0.enabled)] as JSONValue
                }
                let commands = ((try? context.fetch(FetchDescriptor<AutomationCommand>())) ?? []).map {
                    ["name": .string($0.name), "summary": .string($0.summary), "prompt": .string($0.prompt), "enabled": .bool($0.enabled)] as JSONValue
                }
                return ["rules": .array(rules), "commands": .array(commands), "hooks": .array(hooks().map { hook in
                    ["id": .string(hook.id.uuidString), "name": .string(hook.name), "enabled": .bool(hook.enabled),
                     "when": .string(hook.trigger.summary), "do": .string(hook.action.summary), "last_status": hook.lastStatus.map(JSONValue.string) ?? .null]
                })]
            },
            DashiiTool(name: "rules_show", description: "The rules Dashii follows for a scope (global or an extension id): the user's version if they changed it, and the extension's own default. Read them before proposing a change.",
                       properties: ["scope": JSONSchema.string("global or an extension id.")], required: ["scope"]) { input in
                let scope = input["scope"]?.string ?? "global"
                let custom = store.rule(scope)
                let shipped = store.shippedRules(scope)
                return ["scope": .string(scope), "in_use": store.rules(scope).map(JSONValue.string) ?? .null,
                        "customized": .bool(custom != nil), "default": shipped.isEmpty ? .null : .string(shipped.markdown),
                        "list": .string(store.ruleSet(scope).markdown)]
            },
            DashiiTool(name: "automation_set_rules", description: "Propose new rules for Dashii for a scope (global or an extension id): the user sees them and approves before anything changes. Read rules_show first and keep what still applies (its `list`). One rule per line: `- Always: …`, `- Never: …`, `- Prefer: …`, or `- …` for context; `- [off] …` keeps a rule turned off. Empty text goes back to the extension's default.",
                       properties: ["scope": JSONSchema.string("global or an extension id."), "text": JSONSchema.string("The rules, one `- ` line each.")],
                       required: ["scope", "text"], requiresApproval: true) { input in
                let scope = input["scope"]?.string ?? "global", text = input["text"]?.string ?? ""
                if text.isEmpty { store.resetRules(scope) } else { store.setRules(scope, text: text) }
                return "saved"
            },
            DashiiTool(name: "command_save", description: "Create or replace a /command: a named prompt the user types as /name; {{args}} takes what follows it.",
                       properties: ["name": JSONSchema.string("Without the slash."), "summary": JSONSchema.string("One line."), "prompt": JSONSchema.string("The prompt, with {{args}} where the arguments go.")],
                       required: ["name", "prompt"], requiresApproval: true) { input in
                guard let name = input["name"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !name.isEmpty, let prompt = input["prompt"]?.string else {
                    throw ToolError("Give a name and a prompt.")
                }
                try store.saveCommand(name: name, summary: input["summary"]?.string ?? "", prompt: prompt, replacing: name)
                return ["saved": .string("/\(name)")]
            },
            DashiiTool(name: "command_delete", description: "Delete a /command.", properties: ["name": JSONSchema.string("Without the slash.")],
                       required: ["name"], requiresApproval: true) { input in
                store.deleteCommand(input["name"]?.string ?? "")
                return "deleted"
            },
            DashiiTool(name: "hook_presets", description: "Ready-made hooks by use case: watchers (Dash runs a DashQL query itself and fires on new rows, no Dashii), notifications, and wake-ups that hand what a watcher found to an agent. Create one with hook_create preset=<id>.") { _ in
                .array(HookPreset.all(host: host).map { ["id": .string($0.id), "category": .string($0.category), "name": .string($0.name),
                                              "when": .string($0.trigger.summary), "do": .string($0.action.summary)] })
            },
            DashiiTool(name: "hook_create", description: """
                Create a hook: when something happens, do something. trigger is one of {"event": {"kind": "pr.*", "source": null, "contains": null, "criticalOnly": false}}, \
                {"schedule": {"time": "09:00", "weekdays": [2,3,4,5,6]}}, {"launch": {}}, {"beforeTool": {"name": "…"}}, {"afterTool": {"name": "…"}}, \
                or a watcher {"query": {"query": "from pods where restarts > 5", "everyMinutes": 5, "key": "name"}} (Dash runs the DashQL query itself, \
                no Claude, and fires for rows not seen before; prefer it over an agent for "tell me when X appears"). \
                action is one of {"prompt": {"prompt": "…", "noteTitle": null, "notify": true}}, {"command": {"name": "…", "arguments": "", "noteTitle": null, "notify": true}}, \
                {"note": {"title": "…", "folder": null, "body": "…"}}, {"notify": {"title": "…", "body": "…"}}, {"tool": {"name": "…", "input": "{}"}}, \
                {"requireApproval": {"message": "…"}}, {"block": {"message": "…"}}, {"agent": {"id": "<agent id>", "context": "{{rows}}"}} (wake a background agent with what was found). Text takes {{event.title}}, {{date}}, {{tool.input}}, and for watchers {{count}}, {{rows}}, {{first.<field>}}. Shell hooks are made by the user only.
                """,
                       properties: ["name": JSONSchema.string("Hook name."), "trigger": ["type": "object"], "action": ["type": "object"],
                                    "preset": JSONSchema.string("A preset id from hook_presets instead of trigger and action."),
                                    "agent": JSONSchema.string("For wake-an-agent presets: the agent's id (dash_agents).")],
                       required: [], requiresApproval: true) { input in
                if let presetID = input["preset"]?.string {
                    guard let preset = HookPreset.named(presetID, host: host) else { throw ToolError("No preset \(presetID); hook_presets lists them.") }
                    var action = preset.action
                    if case .agent(_, let context) = action {
                        guard let agent = input["agent"]?.string, AgentHub.shared.entry(agent) != nil else {
                            throw ToolError("This preset wakes an agent: give agent=<id> (dash_agents lists them).")
                        }
                        action = .agent(id: agent, context: context)
                    }
                    let hook = AutomationHook(name: input["name"]?.string ?? preset.name, trigger: preset.trigger, action: action)
                    context.insert(hook)
                    try context.save()
                    return ["id": .string(hook.id.uuidString), "when": .string(preset.trigger.summary), "do": .string(action.summary)]
                }
                guard let name = input["name"]?.string, !name.isEmpty else { throw ToolError("Name the hook, or give a preset.") }
                let trigger: HookTrigger, action: HookAction
                do {
                    trigger = try JSONDecoder().decode(HookTrigger.self, from: Data((input["trigger"] ?? .null).jsonString().utf8))
                    action = try JSONDecoder().decode(HookAction.self, from: Data((input["action"] ?? .null).jsonString().utf8))
                } catch {
                    throw ToolError("Trigger or action doesn't match the shapes in the description: \(error.localizedDescription)")
                }
                if case .shell = action { throw ToolError("Shell hooks are made by the user, in Settings › Automation › Hooks.") }
                let hook = AutomationHook(name: name, trigger: trigger, action: action)
                context.insert(hook)
                try context.save()
                return ["id": .string(hook.id.uuidString), "when": .string(trigger.summary), "do": .string(action.summary)]
            },
            DashiiTool(name: "hook_set_enabled", description: "Turn a hook on or off.",
                       properties: ["id": JSONSchema.string("Hook id or name."), "enabled": JSONSchema.boolean("true for on.")],
                       required: ["id", "enabled"], requiresApproval: true) { input in
                let found = try hook(input["id"]?.string)
                found.enabled = input["enabled"]?.bool ?? true
                try context.save()
                return "done"
            },
            DashiiTool(name: "hook_delete", description: "Delete a hook.", properties: ["id": JSONSchema.string("Hook id or name.")],
                       required: ["id"], requiresApproval: true) { input in
                context.delete(try hook(input["id"]?.string))
                try context.save()
                return "deleted"
            },
        ]
    }

    // MARK: Custom agents

    private static func agents(host: ExtensionHost) -> [DashiiTool] {
        let context = host.context
        func agent(_ id: String?) throws -> CustomAgent {
            let all = (try? context.fetch(FetchDescriptor<CustomAgent>())) ?? []
            guard let id, let found = all.first(where: { $0.id.uuidString == id || $0.name.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw ToolError("No custom agent “\(id ?? "")”. dash_agents lists them.")
            }
            return found
        }
        func apply(_ input: JSONValue, to agent: CustomAgent) {
            if let name = input["name"]?.string { agent.name = name }
            if let role = input["role"]?.string { agent.role = role }
            if let instructions = input["instructions"]?.string { agent.instructions = instructions }
            if let scope = input["scope"]?.string { agent.scope = scope }
            if let list = input["specialities"]?.array { agent.specialities = list.compactMap(\.string) }
            if let list = input["integrations"]?.array { agent.integrations = list.compactMap(\.string) }
            if let list = input["events"]?.array { agent.events = list.compactMap(\.string) }
            if let minutes = input["every_minutes"]?.int { agent.everyMinutes = max(0, minutes) }
            if let act = input["can_act"]?.bool { agent.canAct = act }
        }
        let properties: [String: JSONValue] = [
            "name": JSONSchema.string("Name."), "role": JSONSchema.string("e.g. Site reliability engineer."),
            "instructions": JSONSchema.string("What it checks and reports."), "scope": JSONSchema.string("Limits, e.g. only prod."),
            "specialities": ["type": "array", "items": ["type": "string"]], "integrations": ["type": "array", "items": ["type": "string"], "description": "Extension ids whose tools it uses."],
            "events": ["type": "array", "items": ["type": "string"], "description": "Activity kinds that wake it (kubernetes.crashloop, pr.*)."],
            "every_minutes": JSONSchema.integer("Run every N minutes; 0 for events only."),
            "can_act": JSONSchema.boolean("May use tools that change things (each still asks the user). Default false: read-only."),
        ]
        return [
            DashiiTool(name: "agent_create", description: "Create a background agent: a role, instructions, the integrations it reads, and when it runs (every N minutes and/or on activity events). It reports findings; read-only unless can_act.",
                       properties: properties, required: ["name", "instructions"], requiresApproval: true) { input in
                let created = CustomAgent(name: input["name"]?.string ?? "New agent")
                apply(input, to: created)
                context.insert(created)
                try context.save()
                return ["id": .string(created.id.uuidString), "name": .string(created.name)]
            },
            DashiiTool(name: "agent_update", description: "Change a custom agent (only the fields given).",
                       properties: properties.merging(["id": JSONSchema.string("Agent id or name.")]) { a, _ in a }, required: ["id"], requiresApproval: true) { input in
                let found = try agent(input["id"]?.string)
                apply(input, to: found)
                try context.save()
                return ["id": .string(found.id.uuidString), "name": .string(found.name)]
            },
            DashiiTool(name: "agent_delete", description: "Delete a custom agent (its past reports stay).", properties: ["id": JSONSchema.string("Agent id or name.")],
                       required: ["id"], requiresApproval: true) { input in
                context.delete(try agent(input["id"]?.string))
                try context.save()
                return "deleted"
            },
        ]
    }

    // MARK: Opening screens

    private static func open(host: ExtensionHost) -> DashiiTool {
        DashiiTool(name: "open_screen", description: """
            Open a screen for the user: settings (claude, usage, automation, rules, commands, hooks, skills, agents, persona, plugins, marketplace, debug), \
            an extension's settings by id (e.g. jira-board), or the widget gallery (gallery).
            """, properties: ["screen": JSONSchema.string("What to open.")], required: ["screen"]) { input in
            let screen = (input["screen"]?.string ?? "").lowercased()
            switch screen {
            case "gallery", "widget gallery", "widgets": host.openWidgetGallery()
            case "claude", "settings": host.openManager("claude")
            case "usage": host.settingsTab = "claude"; host.claudeSection = "usage"; host.openManagerWindow?()
            case "automation", "rules", "commands", "hooks", "agents", "skills":
                host.settingsTab = "automation"
                host.automationSection = screen == "automation" ? "rules" : screen
                host.openManagerWindow?()
            case "persona", "debug": host.settingsTab = screen; host.openManagerWindow?()
            case "plugins": host.openManager(nil)
            case "marketplace": host.openManager("marketplace")
            default:
                guard let item = host.extensions.first(where: { $0.id == screen || $0.name.lowercased() == screen }) else {
                    throw ToolError("Nothing called “\(screen)” to open.")
                }
                host.openManager(item.id)
            }
            return "opened"
        }
    }
}
