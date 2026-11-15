import DashKit
import DashKitUI
import Foundation
import Testing
@testable import Dash

@MainActor
struct MascotTests {
    private func events(_ importances: [ActivityEvent.Importance]) -> [ActivityEvent] {
        let log = ActivityLog()
        for (index, importance) in importances.enumerated() { log.emit("k", source: "s", title: "event \(index)", importance: importance) }
        return log.events
    }

    @Test func importantModeOnlySurfacesCriticalEvents() {
        let mascot = MascotController(cooldown: 30, greeted: true)
        mascot.observe(events([.info, .notable]), chattiness: .important)
        #expect(mascot.bubble == nil)
        mascot.observe(events([.info, .notable, .critical]), chattiness: .important)
        #expect(mascot.bubble?.text == "event 2" && mascot.bubble?.importance == .critical)
        #expect(mascot.mood(isClaudeWorking: false) == .worried)
    }

    @Test func cooldownQueuesTipsAndDismissShowsTheNext() {
        let mascot = MascotController(cooldown: 30, greeted: true)
        let now = Date()
        mascot.observe(events([.notable, .notable]), chattiness: .everything, now: now)
        #expect(mascot.bubble?.text == "event 0")
        #expect(mascot.queue.map(\.text) == ["event 1"])
        mascot.dismiss(now: now)
        #expect(mascot.bubble?.text == "event 1" && mascot.queue.isEmpty)
    }

    @Test func quietModeNeverTalksAndEventsAreNotReplayed() {
        let mascot = MascotController(cooldown: 0, greeted: true)
        let all = events([.critical])
        mascot.observe(all, chattiness: .quiet)
        #expect(mascot.bubble == nil)
        mascot.observe(all, chattiness: .everything)
        #expect(mascot.bubble == nil)
    }

    @Test func moodFollowsWorkAndIdleness() {
        let mascot = MascotController(greeted: true)
        let now = Date()
        mascot.touch(now: now)
        #expect(mascot.mood(isClaudeWorking: true, now: now) == .thinking)
        #expect(mascot.mood(isClaudeWorking: false, now: now) == .idle)
        #expect(mascot.mood(isClaudeWorking: false, now: now.addingTimeInterval(700)) == .sleepy)
        mascot.react(.happy, for: 3, now: now)
        #expect(mascot.mood(isClaudeWorking: false, now: now.addingTimeInterval(1)) == .happy)
    }

    @Test func personaPromptUsesNameAndVoice() {
        let persona = Persona(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!)
        #expect(persona.name == "Dashii" && persona.tone == .friendly)
        persona.name = "Pixel"
        persona.tone = .playful
        #expect(persona.prompt.contains("You are Pixel") && persona.prompt.contains("dry sense of humour"))
    }
}
