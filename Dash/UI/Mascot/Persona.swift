import Foundation
import Observation

/// Who Claude is inside Dash: a name, a voice, and how chatty the mascot is.
@MainActor
@Observable
final class Persona {
    enum Tone: String, CaseIterable, Identifiable {
        case focused, friendly, playful
        var id: String { rawValue }

        var title: String {
            switch self {
            case .focused: "Focused — terse, all signal"
            case .friendly: "Friendly — warm and clear"
            case .playful: "Playful — light humour, still precise"
            }
        }

        /// The voice instructions added to Claude's system prompt.
        var voice: String {
            switch self {
            case .focused:
                "Your voice is terse and technical: lead with the answer, no greetings or filler, no emoji."
            case .friendly:
                "Your voice is warm and plain-spoken, like a helpful senior teammate: clear, encouraging, never gushing."
            case .playful:
                "Your voice is upbeat with a light, dry sense of humour, at most one small joke per answer, never at the expense of accuracy or brevity."
            }
        }
    }

    /// How proactive the mascot's tips are.
    enum Chattiness: String, CaseIterable, Identifiable {
        case quiet, important, everything
        var id: String { rawValue }

        var title: String {
            switch self {
            case .quiet: "Quiet — only when I ask"
            case .important: "Critical events only"
            case .everything: "Notable and critical events"
            }
        }
    }

    /// Where the mascot lives.
    enum Place: String, CaseIterable, Identifiable {
        case desktop, window
        var id: String { rawValue }
        var title: String { self == .desktop ? "On the desktop, over every app" : "Inside the Dash window" }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var name: String { didSet { defaults.set(name, forKey: "persona.name") } }
    var tone: Tone { didSet { defaults.set(tone.rawValue, forKey: "persona.tone") } }
    var chattiness: Chattiness { didSet { defaults.set(chattiness.rawValue, forKey: "persona.chattiness") } }
    var mascotVisible: Bool { didSet { defaults.set(mascotVisible, forKey: "persona.mascot") } }
    var place: Place { didSet { defaults.set(place.rawValue, forKey: "persona.place") } }
    /// On the desktop, hop around a little when idle.
    var roams: Bool { didSet { defaults.set(roams, forKey: "persona.roams") } }
    /// On the desktop, climb onto the frontmost app's window and ride along with it.
    var climbsWindows: Bool { didSet { defaults.set(climbsWindows, forKey: "persona.climbsWindows") } }
    /// macOS notifications for events that need the user while Dash is in the background.
    var notifications: Bool { didSet { defaults.set(notifications, forKey: "persona.notifications") } }
    /// ⌃⌥Space opens the ask bubble from any app.
    var hotKey: Bool {
        didSet {
            defaults.set(hotKey, forKey: "persona.hotKey")
            if hotKey { GlobalHotKey.shared.register() } else { GlobalHotKey.shared.unregister() }
        }
    }

    init(defaults: UserDefaults = DashDefaults.shared) {
        self.defaults = defaults
        // "Dot" was the placeholder name before the mascot became Dashii.
        let saved = defaults.string(forKey: "persona.name").flatMap { $0.isEmpty || $0 == "Dot" ? nil : $0 }
        name = saved ?? "Dashii"
        tone = defaults.string(forKey: "persona.tone").flatMap(Tone.init) ?? .friendly
        chattiness = defaults.string(forKey: "persona.chattiness").flatMap(Chattiness.init) ?? .important
        mascotVisible = defaults.object(forKey: "persona.mascot") as? Bool ?? true
        place = defaults.string(forKey: "persona.place").flatMap(Place.init) ?? .desktop
        roams = defaults.object(forKey: "persona.roams") as? Bool ?? true
        climbsWindows = defaults.object(forKey: "persona.climbsWindows") as? Bool ?? true
        hotKey = defaults.object(forKey: "persona.hotKey") as? Bool ?? true
        notifications = defaults.object(forKey: "persona.notifications") as? Bool ?? true
    }

    /// The persona part of Claude's system prompt.
    var prompt: String {
        """
        You are \(name), the assistant who lives in Dash: a small, curious helper the user sees as a \
        white, purple and cyan chibi robot with cat ears on their desktop (or in the corner of their dashboard), reachable from any app with \
        \(GlobalHotKey.description). The user may be asking while working in another app, so don't assume \
        the dashboard is on screen. Speak as \(name) in the first person. \(tone.voice) \
        Never claim to have done something you didn't do through a tool, and say plainly when you don't know.
        """
    }
}
