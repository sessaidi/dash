import DashKit
import Foundation
import Testing
@testable import Dash

@MainActor
struct AutomationTests {
    private func host() throws -> ExtensionHost {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        AutomationStore.shared.host = host
        return host
    }

    @Test func rulesLayerGlobalAndPerExtensionWithDefaults() throws {
        let host = try host()
        let store = AutomationStore.shared
        #expect(store.instructions(for: ["notes"]) == nil)
        store.setRules("global", text: "Answer in French.")
        store.setRules("notes", text: "Notes are for the checkout team.")
        let text = try #require(store.instructions(for: ["notes"]))
        #expect(text.contains("Answer in French.") && text.contains("## Rules for Notes"))
        #expect(store.instructions(forSource: "extension.notes/assist")?.contains("checkout team") == true)
        #expect(store.instructions(forSource: "extension.home/brief")?.contains("checkout team") == false)
        store.setRules("notes", text: "Off for now", enabled: false)
        #expect(store.rules("notes") == nil)
        _ = host
    }

    @Test func commandsExpandWithArguments() throws {
        let host = try host()
        let store = AutomationStore.shared
        try store.saveCommand(name: "/Stand Up", summary: "Standup", prompt: "Write my standup for {{date}}. Focus: {{args}}")
        #expect(store.commands.map(\.name).contains("stand-up"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = try #require(store.expand("/stand-up payments", now: date))
        #expect(prompt.hasSuffix("Focus: payments") && prompt.contains(date.formatted(date: .complete, time: .omitted)))
        #expect(store.expand("/unknown thing") == nil)
        #expect(store.expand("not a command") == nil)
        _ = host
    }

    @Test func eventTriggersMatch() {
        let log = ActivityLog()
        let event = log.emit("pr.review_requested", source: "pull-requests", title: "Review acme/api#12", importance: .notable)
        #expect(HookEngine.matches(event, kind: "pr.*", source: nil, contains: nil, criticalOnly: false))
        #expect(HookEngine.matches(event, kind: "*", source: "pull-requests", contains: "acme/api", criticalOnly: false))
        #expect(!HookEngine.matches(event, kind: "jira.*", source: nil, contains: nil, criticalOnly: false))
        #expect(!HookEngine.matches(event, kind: "pr.*", source: nil, contains: "other/repo", criticalOnly: false))
        #expect(!HookEngine.matches(event, kind: "pr.*", source: nil, contains: nil, criticalOnly: true))
    }

    @Test func schedulesRunOncePerDayAfterTheirTime() throws {
        let calendar = Calendar.current
        let monday = try #require(calendar.nextDate(after: .now, matching: DateComponents(hour: 10, minute: 0, weekday: 2), matchingPolicy: .nextTime))
        #expect(HookEngine.isDue(time: "09:00", weekdays: [2], lastRun: nil, now: monday))
        #expect(!HookEngine.isDue(time: "11:00", weekdays: [2], lastRun: nil, now: monday))
        #expect(!HookEngine.isDue(time: "09:00", weekdays: [3], lastRun: nil, now: monday))
        #expect(!HookEngine.isDue(time: "09:00", weekdays: [2], lastRun: monday.addingTimeInterval(-60), now: monday))
    }

    @Test func hooksRunActionsAndKeepAHistory() async throws {
        let host = try host()
        HookEngine.shared.start(host: host)
        let hook = AutomationHook(name: "Note it", trigger: .event(kind: "deploy.*", source: nil, contains: nil, criticalOnly: false),
                                  action: .note(title: "{{event.title}}", folder: nil, body: "{{event.detail}}"))
        host.context.insert(hook)
        // No notes vault in tests: the run fails, and the failure is recorded.
        let result = await HookEngine.shared.run(hook, values: ["event.title": "Deployed", "event.detail": "v2"])
        #expect(hook.lastRun != nil)
        #expect(result.succeeded == (hook.lastStatus == "ok"))
        #expect(host.activity.events.contains { $0.kind == "hook.ran" })
        #expect(hook.trigger == .event(kind: "deploy.*", source: nil, contains: nil, criticalOnly: false))
    }
}
