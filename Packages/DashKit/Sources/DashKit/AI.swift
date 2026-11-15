import Foundation

/// How much thinking power Dashii puts into a task: tasks list the tiers that suit them, and the
/// user picks one per widget or feature in its AI settings. (The raw value is the engine's model
/// id; plugins and users only ever see the tier.)
public enum DashiiModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case strong = "claude-opus-5-5"
    case balanced = "claude-sonnet-5-5"
    case fast = "claude-haiku-5-5"
    case deep = "claude-fable-5-1"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .strong: "Strong"
        case .balanced: "Balanced"
        case .fast: "Fast"
        case .deep: "Deep"
        }
    }

    /// One line on what it's good for, shown under the picker.
    public var note: String {
        switch self {
        case .strong: "Thorough: deep reviews, tricky code."
        case .balanced: "Balanced quality and speed."
        case .fast: "Quickest and cheapest: summaries, triage."
        case .deep: "Most thorough, slowest."
        }
    }
}

/// How hard Dashii thinks about a task.
public enum DashiiEffort: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, medium, high, xhigh, max

    public var id: String { rawValue }
    public var displayName: String { self == .xhigh ? "Extra high" : rawValue.capitalized }
}

/// An editable prompt template, e.g. a PR title. Text uses `{{name}}` placeholders.
public struct AITemplate: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let defaultText: String
    /// Placeholder name to what it holds, shown as insertable chips.
    public let variables: [String: String]
    /// A multi-line editor (descriptions, prompts) rather than a single line (titles).
    public let multiline: Bool

    public init(id: String, title: String, defaultText: String, variables: [String: String] = [:], multiline: Bool = false) {
        self.id = id
        self.title = title
        self.defaultText = defaultText
        self.variables = variables
        self.multiline = multiline
    }
}

/// Something a widget or feature asks Dashii to do (review a PR, write a PR description),
/// declared so the user can pick the model, the effort and the prompt templates.
public struct AITask: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    /// Models that suit the task, best first. The first is the default unless `defaultModel` says otherwise.
    public let models: [DashiiModel]
    public let defaultModel: DashiiModel
    public let efforts: [DashiiEffort]
    public let defaultEffort: DashiiEffort?
    /// Non-nil: the task can be switched off (e.g. "Allow creating PRs"), with this default.
    public let enabledByDefault: Bool?
    public let templates: [AITemplate]

    public init(
        id: String, title: String, summary: String, models: [DashiiModel] = DashiiModel.allCases, defaultModel: DashiiModel? = nil,
        efforts: [DashiiEffort] = [], defaultEffort: DashiiEffort? = nil, enabledByDefault: Bool? = nil, templates: [AITemplate] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        let offered = models.isEmpty ? DashiiModel.allCases : models
        self.models = offered
        self.defaultModel = defaultModel.flatMap { offered.contains($0) ? $0 : nil } ?? offered[0]
        self.efforts = efforts
        self.defaultEffort = defaultEffort ?? efforts.first
        self.enabledByDefault = enabledByDefault
        self.templates = templates
    }
}

/// Where AI choices are saved: one placed widget, or a whole extension (its background work).
public enum AIScope: Hashable, Sendable, CustomStringConvertible {
    case widget(UUID)
    case `extension`(String)

    public var description: String {
        switch self {
        case .widget(let id): "widget.\(id.uuidString)"
        case .extension(let id): "extension.\(id)"
        }
    }
}

/// The user's choices for one task, as saved.
public struct AITaskChoice: Codable, Sendable, Equatable {
    public var model: DashiiModel?
    public var effort: DashiiEffort?
    public var enabled: Bool?
    /// Template id to edited text (missing: the default).
    public var templates: [String: String]

    public init(model: DashiiModel? = nil, effort: DashiiEffort? = nil, enabled: Bool? = nil, templates: [String: String] = [:]) {
        self.model = model
        self.effort = effort
        self.enabled = enabled
        self.templates = templates
    }

    private enum CodingKeys: String, CodingKey { case model, effort, enabled, templates }

    /// A model or effort Dash no longer knows (retired, renamed) falls back to the default
    /// instead of losing the rest of the user's choices.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try? container.decodeIfPresent(DashiiModel.self, forKey: .model)
        effort = try? container.decodeIfPresent(DashiiEffort.self, forKey: .effort)
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        templates = (try? container.decodeIfPresent([String: String].self, forKey: .templates)) ?? [:]
    }
}

/// The resolved AI settings for a scope: the user's choices over each task's defaults.
public struct AISettings: Sendable, Equatable {
    public let tasks: [AITask]
    public var choices: [String: AITaskChoice]
    /// Whose settings these are; requests made with them are attributed to it in usage analytics.
    public var scope: AIScope?

    public init(tasks: [AITask], choices: [String: AITaskChoice] = [:], scope: AIScope? = nil) {
        self.tasks = tasks
        self.choices = choices
        self.scope = scope
    }

    private func task(_ id: String) -> AITask? { tasks.first { $0.id == id } }

    /// The chosen model, if the task still allows it, else the task's default.
    public func model(_ taskID: String) -> DashiiModel {
        guard let task = task(taskID) else { return .balanced }
        if let chosen = choices[taskID]?.model, task.models.contains(chosen) { return chosen }
        return task.defaultModel
    }

    public func effort(_ taskID: String) -> DashiiEffort? {
        guard let task = task(taskID) else { return nil }
        if let chosen = choices[taskID]?.effort, task.efforts.contains(chosen) { return chosen }
        return task.defaultEffort
    }

    /// False only for a switchable task the user (or its default) turned off.
    public func isEnabled(_ taskID: String) -> Bool {
        guard let task = task(taskID), let fallback = task.enabledByDefault else { return true }
        return choices[taskID]?.enabled ?? fallback
    }

    /// The template text (edited or default), not yet filled in.
    public func template(_ taskID: String, _ templateID: String) -> String {
        if let edited = choices[taskID]?.templates[templateID] { return edited }
        return task(taskID)?.templates.first { $0.id == templateID }?.defaultText ?? ""
    }

    /// The template with `{{name}}` placeholders replaced by `values` (unknown names become empty).
    public func render(_ taskID: String, _ templateID: String, _ values: [String: String]) -> String {
        Self.render(template(taskID, templateID), values)
    }

    public static func render(_ text: String, _ values: [String: String]) -> String {
        text.replacing(/\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}/) { match in values[String(match.output.1)] ?? "" }
    }
}

extension DashiiService {
    /// Runs a declared task with the user's model and effort choices, attributed to the task in
    /// Dash's usage analytics ("extension.pull-requests/review").
    public func complete(task taskID: String, settings: AISettings, system: String, prompt: String,
                         outputSchema: JSONValue? = nil) async throws -> String {
        let source = settings.scope.map { "\($0)/\(taskID)" } ?? taskID
        return try await complete(system: system, prompt: prompt, outputSchema: outputSchema,
                                  effort: settings.effort(taskID)?.rawValue, model: settings.model(taskID).rawValue, source: source)
    }
}
