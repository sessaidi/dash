import Foundation

/// The Claude models an AI task can run on. Tasks list the ones that suit them; the user picks
/// one per widget or feature in its AI settings.
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case fable = "claude-fable-5-1"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: "Opus 5.5"
        case .sonnet: "Sonnet 5.5"
        case .haiku: "Haiku 5.5"
        case .fable: "Fable 5.1"
        }
    }

    /// One line on what it's good for, shown under the picker.
    public var note: String {
        switch self {
        case .opus: "Most capable: deep reviews, tricky code."
        case .sonnet: "Balanced quality and speed."
        case .haiku: "Fastest and cheapest: summaries, triage."
        case .fable: "Most capable, slowest."
        }
    }
}

/// How hard Claude thinks (Claude Code's `--effort`).
public enum ClaudeEffort: String, CaseIterable, Codable, Sendable, Identifiable {
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

/// Something a widget or feature asks Claude to do (review a PR, write a PR description),
/// declared so the user can pick the model, the effort and the prompt templates.
public struct AITask: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    /// Models that suit the task, best first. The first is the default unless `defaultModel` says otherwise.
    public let models: [ClaudeModel]
    public let defaultModel: ClaudeModel
    public let efforts: [ClaudeEffort]
    public let defaultEffort: ClaudeEffort?
    /// Non-nil: the task can be switched off (e.g. "Allow creating PRs"), with this default.
    public let enabledByDefault: Bool?
    public let templates: [AITemplate]

    public init(
        id: String, title: String, summary: String, models: [ClaudeModel] = ClaudeModel.allCases, defaultModel: ClaudeModel? = nil,
        efforts: [ClaudeEffort] = [], defaultEffort: ClaudeEffort? = nil, enabledByDefault: Bool? = nil, templates: [AITemplate] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.models = models.isEmpty ? ClaudeModel.allCases : models
        self.defaultModel = defaultModel.flatMap { models.contains($0) ? $0 : nil } ?? self.models[0]
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
    public var model: ClaudeModel?
    public var effort: ClaudeEffort?
    public var enabled: Bool?
    /// Template id to edited text (missing: the default).
    public var templates: [String: String]

    public init(model: ClaudeModel? = nil, effort: ClaudeEffort? = nil, enabled: Bool? = nil, templates: [String: String] = [:]) {
        self.model = model
        self.effort = effort
        self.enabled = enabled
        self.templates = templates
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
    public func model(_ taskID: String) -> ClaudeModel {
        guard let task = task(taskID) else { return .sonnet }
        if let chosen = choices[taskID]?.model, task.models.contains(chosen) { return chosen }
        return task.defaultModel
    }

    public func effort(_ taskID: String) -> ClaudeEffort? {
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

extension ClaudeService {
    /// Runs a declared task with the user's model and effort choices, attributed to the task in
    /// Dash's usage analytics ("extension.pull-requests/review").
    public func complete(task taskID: String, settings: AISettings, system: String, prompt: String,
                         outputSchema: JSONValue? = nil) async throws -> String {
        let source = settings.scope.map { "\($0)/\(taskID)" } ?? taskID
        return try await complete(system: system, prompt: prompt, outputSchema: outputSchema,
                                  effort: settings.effort(taskID)?.rawValue, model: settings.model(taskID).rawValue, source: source)
    }
}
