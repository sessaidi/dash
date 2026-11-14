import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The Home page: who you are (name, role, focus), what to show above the first page's widgets,
/// and the daily brief, where Claude proposes the day's work from your activity.
@MainActor
@Observable
final class HomeExtension: DashExtension {
    let id = "home"
    let name = "Home"
    let systemImage = "house"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "A welcome, an ask bar, suggestions from your plugins and a daily brief from Claude.",
                                     category: .productivity, homepage: "https://github.com/sessaidi/dash")

    struct BriefItem: Codable, Hashable, Identifiable {
        var id: String { title }
        let title: String
        let detail: String?
        let prompt: String?
    }

    struct Brief: Codable, Equatable {
        let items: [BriefItem]
        let date: Date
        let model: String
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var host: (any ExtensionContext)?

    /// About you: used in the greeting, the brief and Claude's instructions.
    var userName: String { didSet { defaults.set(userName, forKey: "home.name") } }
    var role: String { didSet { defaults.set(role, forKey: "home.role") } }
    var focus: String { didSet { defaults.set(focus, forKey: "home.focus") } }
    var showsSuggestions: Bool { didSet { defaults.set(showsSuggestions, forKey: "home.suggestions") } }
    var showsBrief: Bool { didSet { defaults.set(showsBrief, forKey: "home.brief") } }
    /// Write the brief by itself once a day, the first time Home is shown.
    var autoBrief: Bool { didSet { defaults.set(autoBrief, forKey: "home.autoBrief") } }
    private(set) var brief: Brief?
    private(set) var isWritingBrief = false
    private(set) var briefError: String?
    /// Suggestions the user dismissed today.
    private(set) var dismissed: Set<String>

    init(defaults: UserDefaults = DashDefaults.shared) {
        self.defaults = defaults
        userName = defaults.string(forKey: "home.name") ?? Self.givenName(NSFullUserName())
        role = defaults.string(forKey: "home.role") ?? ""
        focus = defaults.string(forKey: "home.focus") ?? ""
        showsSuggestions = defaults.object(forKey: "home.suggestions") as? Bool ?? true
        showsBrief = defaults.object(forKey: "home.brief") as? Bool ?? true
        autoBrief = defaults.object(forKey: "home.autoBrief") as? Bool ?? false
        brief = defaults.data(forKey: "home.lastBrief").flatMap { try? JSONDecoder().decode(Brief.self, from: $0) }
        let dismissedDay = defaults.string(forKey: "home.dismissedDay")
        dismissed = dismissedDay == Self.today ? Set(defaults.stringArray(forKey: "home.dismissed") ?? []) : []
    }

    /// "ESSAÏDI Sadik" or "Sadik Essaïdi" → "Sadik": the given name, in normal case.
    static func givenName(_ fullName: String) -> String {
        let words = fullName.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "" }
        // A name written in capitals is usually the family name ("ESSAÏDI Sadik").
        let given = words.first { $0 != $0.uppercased() } ?? words[0]
        return given.prefix(1).uppercased() + given.dropFirst().lowercased()
    }

    static var today: String { Date.now.formatted(.iso8601.year().month().day()) }

    func start(host: any ExtensionContext) { self.host = host }

    func settingsView() -> AnyView { AnyView(HomeSettings(home: self)) }

    // MARK: About you

    /// For Claude's instructions: who the user is and what they work on.
    var profilePrompt: String? {
        let parts = [userName.isEmpty ? nil : "The user's name is \(userName).",
                     role.isEmpty ? nil : "They are \(role).",
                     focus.isEmpty ? nil : "Their current focus: \(focus)."].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Suggestions

    func dismiss(_ suggestion: Suggestion) {
        dismissed.insert(suggestion.id)
        defaults.set(Array(dismissed), forKey: "home.dismissed")
        defaults.set(Self.today, forKey: "home.dismissedDay")
    }

    // MARK: Daily brief

    static let briefTask = AITask(
        id: "brief", title: "Daily brief",
        summary: "Proposes the day's work from your role, your focus and what happened on your dashboard.",
        models: [.haiku, .sonnet, .opus], defaultModel: .sonnet, efforts: [.low, .medium, .high], defaultEffort: .low,
        enabledByDefault: true,
        templates: [AITemplate(
            id: "prompt", title: "Brief prompt",
            defaultText: """
                Plan today for {{name}}{{role_clause}}.{{focus_clause}}
                Here is what's waiting and what happened recently on their dashboard:
                {{context}}

                Propose 3 to 5 concrete things to do today, most important first. Each needs a short title, \
                one line of detail, and the question they could ask you to get started.
                """,
            variables: ["name": "Your name", "role_clause": "\", a <role>\" when a role is set", "focus_clause": "Your focus, when set",
                        "context": "Suggestions from plugins and recent activity"],
            multiline: true)])

    var aiTasks: [AITask] { [Self.briefTask] }

    static let briefSchema: JSONValue = [
        "type": "object",
        "properties": ["items": ["type": "array", "items": [
            "type": "object",
            "properties": ["title": ["type": "string"], "detail": ["type": "string"], "prompt": ["type": "string"]],
            "required": ["title", "detail", "prompt"],
        ]]],
        "required": ["items"],
    ]

    var briefIsFromToday: Bool { brief.map { Calendar.current.isDateInToday($0.date) } ?? false }

    /// Asks Claude for today's brief, with the user's model and prompt choices.
    func writeBrief(context: String) async {
        guard let host, !isWritingBrief else { return }
        let settings = host.aiSettings(.extension(id), tasks: aiTasks)
        guard settings.isEnabled(Self.briefTask.id) else { return }
        isWritingBrief = true
        defer { isWritingBrief = false }
        let prompt = settings.render(Self.briefTask.id, "prompt", [
            "name": userName.isEmpty ? "the user" : userName,
            "role_clause": role.isEmpty ? "" : ", \(role)",
            "focus_clause": focus.isEmpty ? "" : " Their focus: \(focus).",
            "context": context.isEmpty ? "(nothing yet)" : context,
        ])
        do {
            let text = try await host.claude.complete(task: Self.briefTask.id, settings: settings,
                                                      system: "You help a software developer plan their day. Be concrete and brief.",
                                                      prompt: prompt, outputSchema: Self.briefSchema)
            let items = try JSONValue.parse(text)["items"]?.decode([BriefItem].self) ?? []
            let brief = Brief(items: items, date: .now, model: settings.model(Self.briefTask.id).displayName)
            self.brief = brief
            briefError = nil
            defaults.set(try? JSONEncoder().encode(brief), forKey: "home.lastBrief")
            host.activity.emit("home.brief", source: id, title: "Wrote today's brief (\(items.count) items)")
        } catch {
            briefError = error.localizedDescription
        }
    }
}

private struct HomeSettings: View {
    @Bindable var home: HomeExtension

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $home.userName, prompt: Text("How Dashii greets you"))
                TextField("Role", text: $home.role, prompt: Text("e.g. backend engineer on the payments team"))
                TextField("Focus", text: $home.focus, prompt: Text("e.g. the checkout migration, on-call this week"), axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("About you")
            } footer: {
                Text("Used in the greeting, the daily brief, and Dashii's instructions in every conversation.")
            }
            Section("Home page") {
                Toggle("Suggestions from your plugins and activity", isOn: $home.showsSuggestions)
                Toggle("Daily brief from Claude", isOn: $home.showsBrief)
                Toggle("Write the brief automatically each morning", isOn: $home.autoBrief)
                    .disabled(!home.showsBrief)
            }
        }
    }
}
