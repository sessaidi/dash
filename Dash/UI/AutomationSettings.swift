import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// Settings › Automation: rules Claude follows, `/commands`, and hooks.
struct AutomationSettings: View {
    @Binding var section: String

    var body: some View {
        switch section {
        case "commands": CommandsEditor()
        case "hooks": HooksEditor()
        case "agents": AgentsSettings()
        default: RulesEditor()
        }
    }
}

// MARK: - Rules

/// Global rules plus one entry per extension (its default shown until customized).
struct RulesEditor: View {
    /// Shows just this scope (an extension's detail page); nil lists every scope.
    var only: String?
    @Environment(ExtensionHost.self) private var host
    @State private var selection = "global"
    @State private var text = ""
    @State private var enabled = true
    @State private var revision = 0

    private var scopes: [(id: String, name: String, icon: String)] {
        [("global", "Everything", "globe")] + host.extensions.filter { host.isEnabled($0) && $0.id != "marketplace" }
            .map { ($0.id, $0.name, $0.systemImage) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if only == nil {
                List(scopes, id: \.id, selection: Binding(get: { selection }, set: { if let id = $0 { load(id) } })) { scope in
                    HStack {
                        Label(scope.name, systemImage: scope.icon)
                        Spacer()
                        if AutomationStore.shared.rules(scope.id) != nil { Circle().fill(.tint).frame(width: 6, height: 6) }
                    }
                    .tag(scope.id)
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                .id(revision)
                Divider()
            }
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                    Toggle("Use these rules", isOn: $enabled)
                    HStack {
                        if let defaults = defaultRules, AutomationStore.shared.rule(selection) != nil {
                            Button("Reset to Plugin Default") {
                                AutomationStore.shared.resetRules(selection)
                                text = defaults
                                enabled = true
                                revision += 1
                            }
                        }
                        Spacer()
                        Button("Save") {
                            AutomationStore.shared.setRules(selection, text: text, enabled: enabled)
                            revision += 1
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text(selection == "global" ? "Rules for every conversation" : "Rules for \(scopes.first { $0.id == selection }?.name ?? selection)")
                } footer: {
                    Text(selection == "global"
                         ? "Claude follows these everywhere: the chat, plugin tasks, hooks. Like a CLAUDE.md for Dash."
                         : "Claude follows these whenever this plugin's tools or AI tasks are used.")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { load(only ?? selection) }
    }

    private var defaultRules: String? { host.extensions.first { $0.id == selection }?.defaultRules }

    private func load(_ scope: String) {
        selection = scope
        let saved = AutomationStore.shared.rule(scope)
        text = saved?.text ?? defaultRules ?? ""
        enabled = saved?.enabled ?? true
    }
}

// MARK: - Commands

struct CommandsEditor: View {
    @Environment(ExtensionHost.self) private var host
    @State private var selection: String?
    @State private var name = ""
    @State private var summary = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var revision = 0

    var body: some View {
        let commands = AutomationStore.shared.commands
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(commands, selection: Binding(get: { selection }, set: { if let name = $0 { load(name) } })) { command in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(command.name)").font(.callout.monospaced())
                        Text(command.scope.flatMap { id in host.extensions.first { $0.id == id }?.name } ?? "Yours")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(command.name)
                }
                .listStyle(.sidebar)
                .id(revision)
                Divider()
                Button("New Command", systemImage: "plus") { newCommand() }
                    .buttonStyle(.borderless)
                    .padding(8)
            }
            .frame(width: 200)
            Divider()
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("standup"))
                    TextField("Description", text: $summary, prompt: Text("Write today's standup"))
                    TextEditor(text: $prompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    HStack {
                        if selection != nil, AutomationStore.shared.savedCommand(selection ?? "") != nil {
                            Button(isPluginDefault ? "Reset to Plugin Default" : "Delete", role: .destructive) {
                                AutomationStore.shared.deleteCommand(selection ?? "")
                                revision += 1
                                selection = nil
                                newCommand()
                            }
                        }
                        Spacer()
                        Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    }
                } header: {
                    Text(selection.map { "/\($0)" } ?? "New command")
                } footer: {
                    Text("Type /\(name.isEmpty ? "name" : AutomationStore.commandName(name)) in the chat or the Home ask bar. {{args}} is what you type after the name; {{date}} is today.")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { if selection == nil { newCommand() } }
    }

    private var isPluginDefault: Bool {
        guard let selection else { return false }
        return host.extensions.contains { $0.defaultCommands.contains { $0.name == selection } }
    }

    private func load(_ commandName: String) {
        guard let command = AutomationStore.shared.commands.first(where: { $0.name == commandName }) else { return }
        selection = command.name
        name = command.name
        summary = command.summary
        prompt = command.prompt
        error = nil
    }

    private func newCommand() {
        selection = nil
        name = ""
        summary = ""
        prompt = "Read my open PRs, my Jira tickets in progress and yesterday's notes, then write today's standup as a short note. {{args}}"
        error = nil
    }

    private func save() {
        do {
            let scope = AutomationStore.shared.commands.first { $0.name == selection }?.scope
            try AutomationStore.shared.saveCommand(name: name, summary: summary, prompt: prompt, scope: scope, replacing: selection)
            selection = AutomationStore.commandName(name)
            revision += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Hooks

struct HooksEditor: View {
    @Environment(ExtensionHost.self) private var host
    @Query(sort: \AutomationHook.createdAt) private var hooks: [AutomationHook]
    @State private var selection: AutomationHook.ID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(hooks, selection: $selection) { hook in
                    HStack {
                        StatusDot(hook.lastStatus == nil ? .neutral : hook.lastStatus == "ok" ? .success : .danger,
                                  help: hook.lastStatus ?? "Not run yet")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hook.name).lineLimit(1)
                            Text(hook.trigger.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !hook.enabled { Text("off").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .tag(hook.id)
                }
                .listStyle(.sidebar)
                Divider()
                Menu {
                    Button("Blank Hook") { add(name: "New hook", trigger: .event(kind: "*", source: nil, contains: nil, criticalOnly: true),
                                               action: .notify(title: "{{event.title}}", body: "{{event.detail}}")) }
                    Divider()
                    Button("Summarize meetings into notes") {
                        add(name: "Meeting notes", trigger: .event(kind: "meeting.ended", source: nil, contains: nil, criticalOnly: false),
                            action: .prompt(prompt: "Summarize the meeting “{{event.title}}” with decisions and action items. Use meeting_transcript.",
                                            noteTitle: "{{date}} {{event.title}}", notify: true))
                    }
                    Button("Morning standup at 9:00 on weekdays") {
                        add(name: "Morning standup", trigger: .schedule(time: "09:00", weekdays: [2, 3, 4, 5, 6]),
                            action: .prompt(prompt: "Write my standup from my open PRs, my Jira tickets in progress and yesterday's activity.",
                                            noteTitle: "Standup {{date}}", notify: true))
                    }
                    Button("Ask before Claude comments on GitHub") {
                        add(name: "Approve GitHub comments", trigger: .beforeTool(name: "github_comment"),
                            action: .requireApproval(message: "Claude wants to comment on GitHub."))
                    }
                    Button("Notify me on critical events") {
                        add(name: "Critical alerts", trigger: .event(kind: "*", source: nil, contains: nil, criticalOnly: true),
                            action: .notify(title: "{{event.title}}", body: "{{event.detail}}"))
                    }
                } label: {
                    Label("New Hook", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
            .frame(width: 230)
            Divider()
            if let hook = hooks.first(where: { $0.id == selection }) {
                HookForm(hook: hook) { selection = nil }
                    .id(hook.id)
            } else {
                ContentUnavailableView("No hook selected", systemImage: "bolt",
                                       description: Text("Hooks run something when an event happens, on a schedule, when Dash starts, or around Claude's tool calls."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func add(name: String, trigger: HookTrigger, action: HookAction) {
        let hook = AutomationHook(name: name, trigger: trigger, action: action)
        host.context.insert(hook)
        try? host.context.save()
        selection = hook.id
    }
}

/// Edits one hook: a trigger (event, schedule, launch, before/after a tool) and an action.
private struct HookForm: View {
    @Bindable var hook: AutomationHook
    let onDelete: () -> Void
    @Environment(ExtensionHost.self) private var host
    @Query(sort: \HookRun.date, order: .reverse) private var runs: [HookRun]
    @State private var testing = false
    @State private var testOutput: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $hook.name)
                Toggle("Enabled", isOn: $hook.enabled)
            }
            Section("When") { triggerEditor }
            Section {
                actionEditor
            } header: {
                Text("Then")
            } footer: {
                Text("Placeholders: " + HookEngine.placeholders(for: hook.trigger).map { "{{\($0)}}" }.joined(separator: " "))
            }
            Section {
                HStack {
                    Button("Delete Hook", role: .destructive) {
                        host.context.delete(hook)
                        try? host.context.save()
                        onDelete()
                    }
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Run Now") {
                        testing = true
                        Task {
                            var values = HookEngine.baseValues()
                            values["event.title"] = "Test event"
                            values["event.detail"] = "Run from Settings"
                            testOutput = await HookEngine.shared.run(hook, values: values).output
                            testing = false
                        }
                    }
                    .disabled(testing)
                }
                if let testOutput { Text(testOutput).font(.caption.monospaced()).textSelection(.enabled).lineLimit(8) }
            }
            let mine = runs.filter { $0.hookID == hook.id }.prefix(8)
            if !mine.isEmpty {
                Section("Recent runs") {
                    ForEach(Array(mine)) { run in
                        HStack(alignment: .firstTextBaseline) {
                            StatusDot(run.succeeded ? .success : .danger)
                            Text(run.output).font(.caption).lineLimit(2)
                            Spacer()
                            RelativeTime(run.date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { try? host.context.save() }
    }

    // MARK: Trigger

    private enum TriggerKind: String, CaseIterable { case event, schedule, launch, beforeTool, afterTool }

    private var triggerKind: Binding<TriggerKind> {
        Binding(get: {
            switch hook.trigger {
            case .event: .event
            case .schedule: .schedule
            case .launch: .launch
            case .beforeTool: .beforeTool
            case .afterTool: .afterTool
            }
        }, set: { kind in
            switch kind {
            case .event: hook.trigger = .event(kind: "*", source: nil, contains: nil, criticalOnly: false)
            case .schedule: hook.trigger = .schedule(time: "09:00", weekdays: [2, 3, 4, 5, 6])
            case .launch: hook.trigger = .launch
            case .beforeTool: hook.trigger = .beforeTool(name: host.availableTools.first?.name ?? "*")
            case .afterTool: hook.trigger = .afterTool(name: host.availableTools.first?.name ?? "*")
            }
        })
    }

    @ViewBuilder
    private var triggerEditor: some View {
        Picker("Trigger", selection: triggerKind) {
            Text("An event happens").tag(TriggerKind.event)
            Text("On a schedule").tag(TriggerKind.schedule)
            Text("Dash starts").tag(TriggerKind.launch)
            Text("Before Claude runs a tool").tag(TriggerKind.beforeTool)
            Text("After Claude ran a tool").tag(TriggerKind.afterTool)
        }
        switch hook.trigger {
        case .event(let kind, let source, let contains, let criticalOnly):
            HStack {
                TextField("Event", text: Binding(get: { kind }, set: { hook.trigger = .event(kind: $0, source: source, contains: contains, criticalOnly: criticalOnly) }),
                          prompt: Text("pr.* or meeting.ended"))
                Menu("Known") {
                    Button("Any event (*)") { hook.trigger = .event(kind: "*", source: source, contains: contains, criticalOnly: criticalOnly) }
                    ForEach(knownEvents, id: \.0) { event in
                        Button("\(event.0)\(event.1.isEmpty ? "" : " — \(event.1)")") {
                            hook.trigger = .event(kind: event.0, source: source, contains: contains, criticalOnly: criticalOnly)
                        }
                    }
                }
                .fixedSize()
            }
            TextField("Only from", text: Binding(get: { source ?? "" }, set: { hook.trigger = .event(kind: kind, source: $0.isEmpty ? nil : $0, contains: contains, criticalOnly: criticalOnly) }),
                      prompt: Text("any extension (e.g. pull-requests)"))
            TextField("Only if it mentions", text: Binding(get: { contains ?? "" }, set: { hook.trigger = .event(kind: kind, source: source, contains: $0.isEmpty ? nil : $0, criticalOnly: criticalOnly) }),
                      prompt: Text("e.g. acme/api"))
            Toggle("Only critical events", isOn: Binding(get: { criticalOnly }, set: { hook.trigger = .event(kind: kind, source: source, contains: contains, criticalOnly: $0) }))
        case .schedule(let time, let weekdays):
            DatePicker("Time", selection: Binding(get: { Self.date(time) }, set: { hook.trigger = .schedule(time: Self.time($0), weekdays: weekdays) }),
                       displayedComponents: .hourAndMinute)
            HStack {
                ForEach(1...7, id: \.self) { day in
                    Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                        get: { weekdays.contains(day) },
                        set: { on in hook.trigger = .schedule(time: time, weekdays: on ? weekdays + [day] : weekdays.filter { $0 != day }) }))
                    .toggleStyle(.button)
                }
            }
        case .launch:
            Text("Runs each time Dash opens.").foregroundStyle(.secondary)
        case .beforeTool(let name):
            toolPicker(name) { hook.trigger = .beforeTool(name: $0) }
        case .afterTool(let name):
            toolPicker(name) { hook.trigger = .afterTool(name: $0) }
        }
    }

    private func toolPicker(_ name: String, set: @escaping (String) -> Void) -> some View {
        Picker("Tool", selection: Binding(get: { name }, set: set)) {
            Text("Any tool").tag("*")
            ForEach(host.availableTools.map(\.name).sorted(), id: \.self) { Text($0).tag($0) }
            if name != "*", !host.availableTools.contains(where: { $0.name == name }) { Text(name).tag(name) }
        }
    }

    /// Declared by extensions, plus kinds already seen in the activity log.
    private var knownEvents: [(String, String)] {
        var events = host.extensions.flatMap(\.events).map { ($0.kind, $0.summary) }
        let declared = Set(events.map(\.0))
        for kind in Set(host.activity.events.map(\.kind)).sorted() where !declared.contains(kind) && !kind.hasPrefix("hook.") {
            events.append((kind, ""))
        }
        return events
    }

    // MARK: Action

    private enum ActionKind: String, CaseIterable { case prompt, command, note, notify, tool, shell, requireApproval, block }

    private var actionKind: Binding<ActionKind> {
        Binding(get: {
            switch hook.action {
            case .prompt: .prompt
            case .command: .command
            case .note: .note
            case .notify: .notify
            case .tool: .tool
            case .shell: .shell
            case .requireApproval: .requireApproval
            case .block: .block
            }
        }, set: { kind in
            switch kind {
            case .prompt: hook.action = .prompt(prompt: "", noteTitle: nil, notify: true)
            case .command: hook.action = .command(name: AutomationStore.shared.commands.first?.name ?? "", arguments: "", noteTitle: nil, notify: true)
            case .note: hook.action = .note(title: "{{date}} {{event.title}}", folder: nil, body: "{{event.detail}}")
            case .notify: hook.action = .notify(title: "{{event.title}}", body: "{{event.detail}}")
            case .tool: hook.action = .tool(name: host.availableTools.first?.name ?? "", input: "{}")
            case .shell: hook.action = .shell(command: "")
            case .requireApproval: hook.action = .requireApproval(message: "Claude wants to run {{tool.name}}.")
            case .block: hook.action = .block(message: "Not allowed by the user's hook.")
            }
        })
    }

    @ViewBuilder
    private var actionEditor: some View {
        Picker("Action", selection: actionKind) {
            Text("Ask Claude").tag(ActionKind.prompt)
            Text("Run a /command").tag(ActionKind.command)
            Text("Create a note").tag(ActionKind.note)
            Text("Notify me").tag(ActionKind.notify)
            Text("Run a tool").tag(ActionKind.tool)
            Text("Run a shell command").tag(ActionKind.shell)
            if case .beforeTool = hook.trigger {
                Text("Ask me first").tag(ActionKind.requireApproval)
                Text("Block it").tag(ActionKind.block)
            }
        }
        switch hook.action {
        case .prompt(let prompt, let noteTitle, let notify):
            TextEditor(text: Binding(get: { prompt }, set: { hook.action = .prompt(prompt: $0, noteTitle: noteTitle, notify: notify) }))
                .font(.body.monospaced()).frame(minHeight: 90).scrollContentBackground(.hidden)
            TextField("Save the answer as a note", text: Binding(get: { noteTitle ?? "" }, set: { hook.action = .prompt(prompt: prompt, noteTitle: $0.isEmpty ? nil : $0, notify: notify) }),
                      prompt: Text("Note title (empty: don't save)"))
            Toggle("Notify me with the answer", isOn: Binding(get: { notify }, set: { hook.action = .prompt(prompt: prompt, noteTitle: noteTitle, notify: $0) }))
        case .command(let name, let arguments, let noteTitle, let notify):
            Picker("Command", selection: Binding(get: { name }, set: { hook.action = .command(name: $0, arguments: arguments, noteTitle: noteTitle, notify: notify) })) {
                ForEach(AutomationStore.shared.commands) { Text("/\($0.name)").tag($0.name) }
                if !AutomationStore.shared.commands.contains(where: { $0.name == name }) { Text("/\(name)").tag(name) }
            }
            TextField("Arguments", text: Binding(get: { arguments }, set: { hook.action = .command(name: name, arguments: $0, noteTitle: noteTitle, notify: notify) }))
            TextField("Save the answer as a note", text: Binding(get: { noteTitle ?? "" }, set: { hook.action = .command(name: name, arguments: arguments, noteTitle: $0.isEmpty ? nil : $0, notify: notify) }),
                      prompt: Text("Note title (empty: don't save)"))
            Toggle("Notify me with the answer", isOn: Binding(get: { notify }, set: { hook.action = .command(name: name, arguments: arguments, noteTitle: noteTitle, notify: $0) }))
        case .note(let title, let folder, let body):
            TextField("Title", text: Binding(get: { title }, set: { hook.action = .note(title: $0, folder: folder, body: body) }))
            TextField("Folder", text: Binding(get: { folder ?? "" }, set: { hook.action = .note(title: title, folder: $0.isEmpty ? nil : $0, body: body) }),
                      prompt: Text("optional"))
            TextEditor(text: Binding(get: { body }, set: { hook.action = .note(title: title, folder: folder, body: $0) }))
                .font(.body.monospaced()).frame(minHeight: 90).scrollContentBackground(.hidden)
        case .notify(let title, let body):
            TextField("Title", text: Binding(get: { title }, set: { hook.action = .notify(title: $0, body: body) }))
            TextField("Message", text: Binding(get: { body }, set: { hook.action = .notify(title: title, body: $0) }))
        case .tool(let name, let input):
            Picker("Tool", selection: Binding(get: { name }, set: { hook.action = .tool(name: $0, input: input) })) {
                ForEach(host.availableTools.map(\.name).sorted(), id: \.self) { Text($0).tag($0) }
                if !host.availableTools.contains(where: { $0.name == name }) { Text(name).tag(name) }
            }
            TextEditor(text: Binding(get: { input }, set: { hook.action = .tool(name: name, input: $0) }))
                .font(.body.monospaced()).frame(minHeight: 70).scrollContentBackground(.hidden)
        case .shell(let command):
            TextField("Command", text: Binding(get: { command }, set: { hook.action = .shell(command: $0) }), prompt: Text("e.g. say {{event.title}}"))
                .font(.body.monospaced())
            Label("Dash asks you before every run.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        case .requireApproval(let message):
            TextField("Message", text: Binding(get: { message }, set: { hook.action = .requireApproval(message: $0) }))
        case .block(let message):
            TextField("Reason told to Claude", text: Binding(get: { message }, set: { hook.action = .block(message: $0) }))
        }
    }

    private static func date(_ time: String) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: .now) ?? .now
    }

    private static func time(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
