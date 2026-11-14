import DashKit
import Foundation
import Observation

/// The mascot's state: mood, the speech bubble, and which dashboard events become tips.
@MainActor
@Observable
final class MascotController {
    enum Mood: Equatable {
        case idle, thinking, happy, worried, sleepy, talking
        /// The ask field is open: waiting for the question.
        case listening
    }

    struct Bubble: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A proactive tip about an activity event.
            case tip(eventID: Int, link: String?)
            /// The quick-ask text field.
            case ask
            /// Claude's latest answer, previewed.
            case answer
            case greeting
        }

        let id = UUID()
        let kind: Kind
        let text: String
        let importance: ActivityEvent.Importance
    }

    private(set) var bubble: Bubble?
    private(set) var moodOverride: (mood: Mood, until: Date)?
    private(set) var lastInteraction = Date()
    /// Tips waiting while another bubble shows.
    private(set) var queue: [Bubble] = []
    /// Tips waiting behind the current bubble.
    var unread: Int { queue.count }
    /// Jumping for a couple of seconds after a tip arrives.
    var attention: Bool { (attentionUntil ?? .distantPast) > Date() }
    private(set) var attentionUntil: Date?
    /// Events already shown or skipped.
    @ObservationIgnored private var seenEventID = 0
    @ObservationIgnored private var lastTip = Date.distantPast
    @ObservationIgnored private let cooldown: TimeInterval
    @ObservationIgnored private var greeted: Bool

    init(cooldown: TimeInterval = 30, greeted: Bool = DashDefaults.shared.bool(forKey: "persona.greeted")) {
        self.cooldown = cooldown
        self.greeted = greeted
    }

    /// Mood from what's going on, unless a short-lived reaction (happy, worried) is active.
    func mood(isClaudeWorking: Bool, now: Date = Date()) -> Mood {
        if isClaudeWorking { return .thinking }
        if let moodOverride, moodOverride.until > now { return moodOverride.mood }
        if let bubble {
            if bubble.importance == .critical { return .worried }
            return bubble.kind == .ask ? .listening : .talking
        }
        if now.timeIntervalSince(lastInteraction) > 600 { return .sleepy }
        return .idle
    }

    /// The Dashii clip that acts out a mood.
    static func clip(for mood: Mood) -> DashiiClip {
        switch mood {
        // Talking is idle plus a procedural chat gesture (see DashiiDirection.talking).
        case .idle, .sleepy, .talking: .idle
        case .thinking: .thinking
        case .listening: .asking
        case .happy: .success
        case .worried: .error
        }
    }

    func react(_ mood: Mood, for seconds: TimeInterval = 3, now: Date = Date()) {
        moodOverride = (mood, now.addingTimeInterval(seconds))
    }

    func touch(now: Date = Date()) { lastInteraction = now }

    func greetIfNeeded(name: String) {
        guard !greeted else { return }
        greeted = true
        DashDefaults.shared.set(true, forKey: "persona.greeted")
        show(Bubble(kind: .greeting, text: "Hi, I'm \(name)! Click me to ask anything, drag me wherever I'm out of the way, and I'll pipe up when something needs you.", importance: .info))
    }

    /// Turns new activity into tips according to `chattiness`, respecting a cooldown.
    func observe(_ events: [ActivityEvent], chattiness: Persona.Chattiness, now: Date = Date()) {
        let fresh = events.filter { $0.id > seenEventID }
        guard let newest = fresh.last else { return }
        seenEventID = newest.id
        let minimum: ActivityEvent.Importance
        switch chattiness {
        case .quiet: return
        case .important: minimum = .critical
        case .everything: minimum = .notable
        }
        let worth = fresh.filter { $0.importance >= minimum }
        guard !worth.isEmpty else { return }
        for event in worth.suffix(3) {
            let tip = Bubble(kind: .tip(eventID: event.id, link: event.link), text: event.title + (event.detail.map { ". \($0)" } ?? ""), importance: event.importance)
            if bubble == nil, now.timeIntervalSince(lastTip) >= cooldown || event.importance == .critical {
                show(tip, now: now)
            } else if queue.count < 3 {
                queue.append(tip)
            }
        }
    }

    func show(_ bubble: Bubble, now: Date = Date()) {
        self.bubble = bubble
        if case .tip = bubble.kind {
            lastTip = now
            attentionUntil = now.addingTimeInterval(bubble.importance == .critical ? 3 : 1.6)
            react(bubble.importance == .critical ? .worried : .talking, for: 2, now: now)
        }
    }

    func openAsk() {
        touch()
        bubble = Bubble(kind: .ask, text: "", importance: .info)
    }

    func showAnswer(_ text: String) {
        // The bubble scrolls; very long answers are cut with a pointer to the full chat.
        let preview = text.count > 4000 ? String(text.prefix(4000)) + "…" : text
        bubble = Bubble(kind: .answer, text: preview, importance: .info)
        react(.happy, for: 2.5)
    }

    func clearQueue() { queue = [] }

    /// Closes the bubble and shows the next queued tip, if any.
    func dismiss(now: Date = Date()) {
        touch(now: now)
        bubble = nil
        if !queue.isEmpty { show(queue.removeFirst(), now: now) }
    }
}
