import DashKit
import Foundation

/// Ready-made hooks: Dash's own generic ones (critical events, agent findings, a morning brief…)
/// plus whatever enabled extensions offer for their data (`DashExtension.hookPresets`), so a
/// plugin's watchers come and go with the plugin.
struct HookPreset: Identifiable {
    let id: String
    let category: String
    let name: String
    let trigger: HookTrigger
    let action: HookAction

    /// The dataset a watcher reads.
    var dataset: String? {
        guard case .query(let query, _, _) = trigger else { return nil }
        return query.split(separator: " ").dropFirst().first.map(String.init)
    }

    /// Dash's own, about Dash itself and any plugin's events.
    static let generic: [HookPreset] = [
        HookPreset(id: "dash.notify-critical", category: "Notifications", name: "Anything critical",
                   trigger: .event(kind: "*", source: nil, contains: nil, criticalOnly: true), action: .notify(title: "{{event.title}}", body: "{{event.detail}}")),
        HookPreset(id: "dash.notify-agent-findings", category: "Notifications", name: "An agent reports findings",
                   trigger: .event(kind: "agent.finding", source: nil, contains: nil, criticalOnly: false), action: .notify(title: "{{event.title}}", body: "{{event.detail}}")),
        HookPreset(id: "dash.notify-plugin-installed", category: "Notifications", name: "A plugin was installed (turned off)",
                   trigger: .event(kind: "plugin.installed_off", source: nil, contains: nil, criticalOnly: false), action: .notify(title: "{{event.title}}", body: "{{event.detail}}")),
        HookPreset(id: "dash.morning-brief", category: "Routines", name: "Morning brief at 9:00 on weekdays",
                   trigger: .schedule(time: "09:00", weekdays: [2, 3, 4, 5, 6]),
                   action: .prompt(prompt: "Write my morning brief: what changed overnight on my PRs, tickets, releases and alerts.", noteTitle: "Brief {{date}}", notify: true)),
        HookPreset(id: "dash.meeting-notes", category: "Routines", name: "Meeting ended: write notes",
                   trigger: .event(kind: "meeting.ended", source: nil, contains: nil, criticalOnly: false),
                   action: .prompt(prompt: "Summarize the meeting “{{event.title}}” with decisions and action items.", noteTitle: "{{date}} {{event.title}}", notify: true)),
    ]

    /// Generic presets first, then each enabled extension's, under its category (or its name).
    @MainActor
    static func all(host: ExtensionHost) -> [HookPreset] {
        generic + host.extensions.filter { host.isEnabled($0) }.flatMap { item in
            item.hookPresets.compactMap { preset(from: $0, category: $0.category ?? item.name) }
        }
    }

    @MainActor
    static func named(_ id: String, host: ExtensionHost) -> HookPreset? { all(host: host).first { $0.id == id } }

    /// Categories in the order presets come.
    @MainActor
    static func categories(host: ExtensionHost) -> [String] {
        var seen: [String] = []
        for preset in all(host: host) where !seen.contains(preset.category) { seen.append(preset.category) }
        return seen
    }

    /// nil for a kind of preset this Dash doesn't know (a plugin built for a newer DashKit).
    static func preset(from spec: HookPresetSpec, category: String) -> HookPreset? {
        let trigger: HookTrigger
        switch spec.trigger {
        case .watch(let query, let minutes, let key): trigger = .query(query: query, everyMinutes: minutes, key: key)
        case .event(let kind, let criticalOnly): trigger = .event(kind: kind, source: nil, contains: nil, criticalOnly: criticalOnly)
        case .schedule(let time, let weekdays): trigger = .schedule(time: time, weekdays: weekdays)
        @unknown default: return nil
        }
        let action: HookAction
        switch spec.action {
        case .notify(let title, let body): action = .notify(title: title, body: body)
        case .wakeAgent(let context): action = .agent(id: "", context: context)
        case .ask(let prompt, let noteTitle): action = .prompt(prompt: prompt, noteTitle: noteTitle, notify: true)
        @unknown default: return nil
        }
        return HookPreset(id: spec.id, category: category, name: spec.name, trigger: trigger, action: action)
    }
}
