import AppKit
import DashKit
import Foundation
import SwiftData

/// Runs the user's hooks: on activity events, on a schedule, when Dash starts, and around
/// Claude's tool calls. Every run is logged (Settings › Automation › Hooks) and shows up in the
/// activity Claude reads.
@MainActor
final class HookEngine {
    static let shared = HookEngine()

    private weak var host: ExtensionHost?
    private var timer: Timer?
    private var started = false

    enum ToolDecision: Equatable {
        case allow
        case deny(String)
    }

    func start(host: ExtensionHost) {
        self.host = host
        guard !started else { return }
        started = true
        host.activity.onEmit { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // Schedules are checked every 30 seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedules() }
        }
        for hook in hooks() where hook.enabled {
            if case .launch = hook.trigger { Task { await run(hook, values: Self.baseValues()) } }
        }
        checkSchedules()
    }

    func hooks() -> [AutomationHook] {
        (try? host?.context.fetch(FetchDescriptor<AutomationHook>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    // MARK: Triggers

    private func handle(_ event: ActivityEvent) {
        // Hooks' own runs don't trigger hooks (no loops).
        guard event.source != "hooks", event.source != "automation" else { return }
        for hook in hooks() where hook.enabled {
            guard case .event(let kind, let source, let contains, let criticalOnly) = hook.trigger,
                  Self.matches(event, kind: kind, source: source, contains: contains, criticalOnly: criticalOnly) else { continue }
            Task { await run(hook, values: Self.values(for: event)) }
        }
    }

    static func matches(_ event: ActivityEvent, kind: String, source: String?, contains: String?, criticalOnly: Bool) -> Bool {
        let kindMatches = kind == "*" || kind == event.kind || (kind.hasSuffix("*") && event.kind.hasPrefix(String(kind.dropLast())))
        guard kindMatches else { return false }
        if let source, !source.isEmpty, source != event.source { return false }
        if criticalOnly, event.importance != .critical { return false }
        if let contains, !contains.isEmpty {
            let text = event.title + " " + (event.detail ?? "")
            if !text.localizedCaseInsensitiveContains(contains) { return false }
        }
        return true
    }

    private func checkSchedules(now: Date = .now) {
        for hook in hooks() where hook.enabled {
            guard case .schedule(let time, let weekdays) = hook.trigger, Self.isDue(time: time, weekdays: weekdays, lastRun: hook.lastRun, now: now) else { continue }
            hook.lastRun = now  // claimed before running, so a slow run isn't started twice
            Task { await run(hook, values: Self.baseValues(now: now)) }
        }
    }

    /// Due when today is one of the weekdays, the time has passed, and it hasn't run since.
    static func isDue(time: String, weekdays: [Int], lastRun: Date?, now: Date) -> Bool {
        let calendar = Calendar.current
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, weekdays.contains(calendar.component(.weekday, from: now)),
              let due = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now), now >= due else { return false }
        return (lastRun ?? .distantPast) < due
    }

    /// Before Claude runs a tool: the first matching hook can make it ask first or refuse.
    func beforeTool(_ name: String, input: JSONValue) async -> ToolDecision {
        guard let host else { return .allow }
        for hook in hooks() where hook.enabled {
            guard case .beforeTool(let tool) = hook.trigger, tool == name || tool == "*" else { continue }
            let values = Self.toolValues(name, input: input, result: nil)
            switch hook.action {
            case .block(let message):
                record(hook, succeeded: true, output: "Blocked \(name)")
                return .deny(HookTemplate.fill(message, values))
            case .requireApproval(let message):
                let allowed = await host.permissions.ask(
                    icon: "bolt.shield", title: "Hook “\(hook.name)”: allow \(name)?", message: HookTemplate.fill(message, values),
                    details: [.init(title: "Input", text: input.jsonString(pretty: true))], allowLabel: "Allow", denyLabel: "Refuse")
                record(hook, succeeded: true, output: allowed ? "Allowed \(name)" : "Refused \(name)")
                if !allowed { return .deny("The user's hook “\(hook.name)” refused this.") }
            default:
                await run(hook, values: values)
            }
        }
        return .allow
    }

    /// After Claude ran a tool.
    func afterTool(_ name: String, input: JSONValue, result: String) {
        for hook in hooks() where hook.enabled {
            guard case .afterTool(let tool) = hook.trigger, tool == name || tool == "*" else { continue }
            Task { await run(hook, values: Self.toolValues(name, input: input, result: result)) }
        }
    }

    // MARK: Running

    /// Runs a hook's action; `values` fill its `{{placeholders}}`.
    @discardableResult
    func run(_ hook: AutomationHook, values: [String: String]) async -> (succeeded: Bool, output: String) {
        guard let host else { return (false, "Dash isn't ready.") }
        let fill = { (text: String) in HookTemplate.fill(text, values) }
        do {
            let output: String
            switch hook.action {
            case .prompt(let prompt, let noteTitle, let notify):
                output = try await ask(fill(prompt), hook: hook, noteTitle: noteTitle.map(fill), notify: notify)
            case .command(let name, let arguments, let noteTitle, let notify):
                guard let prompt = AutomationStore.shared.expand("/\(name) \(fill(arguments))") else {
                    throw ToolError("There's no /\(name) command.")
                }
                output = try await ask(prompt, hook: hook, noteTitle: noteTitle.map(fill), notify: notify)
            case .note(let title, let folder, let body):
                let url = try host.createNote(title: fill(title), markdown: fill(body), folder: folder.map(fill))
                output = "Created \(url.lastPathComponent)"
            case .notify(let title, let body):
                Notifier.shared.notifyNow(title: fill(title), body: fill(body))
                output = "Notified: \(fill(title))"
            case .tool(let name, let input):
                guard let tool = host.availableTools.first(where: { $0.name == name }) else { throw ToolError("No available tool \(name).") }
                let json = try JSONValue.parse(fill(input).isEmpty ? "{}" : fill(input))
                if tool.requiresApproval {
                    let allowed = await host.permissions.ask(icon: "bolt", title: "Hook “\(hook.name)” wants to run \(name)",
                                                             message: tool.description, details: [.init(title: "Input", text: json.jsonString(pretty: true))])
                    guard allowed else { throw ToolError("You refused it.") }
                }
                output = try await tool.run(json).jsonString()
            case .shell(let command):
                output = try await shell(fill(command), hook: hook)
            case .requireApproval, .block:
                output = "Only applies before a tool runs."
            }
            record(hook, succeeded: true, output: output)
            return (true, output)
        } catch {
            record(hook, succeeded: false, output: error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    private func ask(_ prompt: String, hook: AutomationHook, noteTitle: String?, notify: Bool) async throws -> String {
        guard let host else { throw ToolError("Dash isn't ready.") }
        let system = "You're running the user's automation “\(hook.name)” in Dash. Answer directly in Markdown, no preamble."
            + (AutomationStore.shared.instructions(for: []).map { "\n\n" + $0 } ?? "")
        let answer = try await host.claude.complete(system: system, prompt: prompt, outputSchema: nil, effort: nil, model: nil,
                                                    source: "hook.\(hook.name)")
        if let noteTitle, !noteTitle.trimmed.isEmpty {
            _ = try host.createNote(title: noteTitle, markdown: answer, folder: "Automations")
        }
        if notify { Notifier.shared.notifyNow(title: hook.name, body: String(answer.prefix(240))) }
        return answer
    }

    /// Asks every time, showing the exact command, then runs it with a 60-second limit.
    private func shell(_ command: String, hook: AutomationHook) async throws -> String {
        guard let host else { throw ToolError("Dash isn't ready.") }
        let allowed = await host.permissions.ask(
            icon: "terminal", title: "Hook “\(hook.name)” wants to run a command",
            message: "It runs in your shell with your permissions.", details: [.init(title: "Command", text: command)],
            allowLabel: "Run", denyLabel: "Don't Run")
        guard allowed else { throw ToolError("You refused the command.") }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate() }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw ToolError("Exited \(process.terminationStatus): \(output.suffix(500))") }
            return output
        }.value
    }

    private func record(_ hook: AutomationHook, succeeded: Bool, output: String) {
        guard let host else { return }
        hook.lastRun = .now
        hook.lastStatus = succeeded ? "ok" : output
        host.context.insert(HookRun(hook: hook, succeeded: succeeded, output: output))
        try? host.context.save()
        host.activity.emit("hook.ran", source: "hooks", title: "Hook “\(hook.name)” \(succeeded ? "ran" : "failed")",
                           detail: String(output.prefix(200)), importance: succeeded ? .info : .notable)
    }

    // MARK: Values

    static func baseValues(now: Date = .now) -> [String: String] {
        ["date": now.formatted(.iso8601.year().month().day()), "time": now.formatted(date: .omitted, time: .shortened),
         "weekday": now.formatted(.dateTime.weekday(.wide))]
    }

    static func values(for event: ActivityEvent) -> [String: String] {
        baseValues().merging([
            "event.kind": event.kind, "event.source": event.source, "event.title": event.title,
            "event.detail": event.detail ?? "", "event.link": event.link ?? "", "event.importance": event.importance.rawValue,
        ]) { _, new in new }
    }

    static func toolValues(_ name: String, input: JSONValue, result: String?) -> [String: String] {
        baseValues().merging(["tool.name": name, "tool.input": input.jsonString(), "tool.result": result ?? ""]) { _, new in new }
    }

    /// Placeholders a trigger offers, for the editor.
    static func placeholders(for trigger: HookTrigger) -> [String] {
        var names = ["date", "time", "weekday"]
        switch trigger {
        case .event: names += ["event.title", "event.detail", "event.kind", "event.source", "event.link", "event.importance"]
        case .beforeTool: names += ["tool.name", "tool.input"]
        case .afterTool: names += ["tool.name", "tool.input", "tool.result"]
        default: break
        }
        return names
    }
}
