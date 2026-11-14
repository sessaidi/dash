import DashKitUI
import SwiftUI

/// A dashboard widget kind. Each placed widget stores a `Config` as JSON;
/// Claude can create and reconfigure widgets through that same JSON.
@MainActor
public protocol DashboardWidget {
    associatedtype Config: Codable & Equatable & Sendable
    associatedtype Content: View
    associatedtype Settings: View = EmptyView
    associatedtype Preview: View = EmptyView

    static var kind: String { get }
    static var displayName: String { get }
    /// One sentence, shown in the add menu and to Claude.
    static var summary: String { get }
    static var systemImage: String { get }
    static var defaultConfig: Config { get }
    static var defaultSize: WidgetSize { get }
    /// How small and large it may be resized, in grid cells (12 columns, 40 pt rows).
    static var sizeLimits: GridLimits { get }
    /// What it asks Claude to do. Each placed widget gets an AI tab to pick the model, effort
    /// and prompt templates; read them with `context.ai`.
    static var aiTasks: [AITask] { get }
    /// JSON schema of `Config`, given to Claude so it can configure the widget.
    static var configSchema: JSONValue { get }

    @ViewBuilder static func content(config: Binding<Config>, context: WidgetContext) -> Content
    @ViewBuilder static func settings(config: Binding<Config>, context: WidgetContext) -> Settings
    /// What the widget looks like, drawn from sample data: shown in the widget gallery and in
    /// Settings. It must not touch the network or the user's accounts. Without one, Dash shows a
    /// neutral placeholder.
    @ViewBuilder static func preview(config: Config) -> Preview
    /// The widget's current data as JSON, read by Claude with `read_widget`.
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue
}

extension DashboardWidget where Settings == EmptyView {
    public static func settings(config: Binding<Config>, context: WidgetContext) -> EmptyView { EmptyView() }
}

extension DashboardWidget where Preview == EmptyView {
    public static func preview(config: Config) -> EmptyView { EmptyView() }
}

extension DashboardWidget {
    public static var defaultSize: WidgetSize { .medium }
    public static var sizeLimits: GridLimits { GridLimits() }
    public static var aiTasks: [AITask] { [] }
    public static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        (try? JSONValue(encoding: config)) ?? .null
    }
}

public struct WidgetContext: Sendable {
    public let widgetID: UUID
    public let host: any ExtensionContext
    /// The widget type's AI tasks (set by Dash).
    public let aiTasks: [AITask]

    public init(widgetID: UUID, host: any ExtensionContext, aiTasks: [AITask] = []) {
        self.widgetID = widgetID
        self.host = host
        self.aiTasks = aiTasks
    }

    /// This widget's AI choices (model, effort, templates), read fresh each time.
    @MainActor
    public var ai: AISettings { host.aiSettings(.widget(widgetID), tasks: aiTasks) }
}

public enum WidgetSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large, wide

    /// Preset size in grid cells (12 columns, 40 pt rows). Users fine-tune by resizing.
    public var cells: (w: Int, h: Int) {
        switch self {
        case .small: (3, 4)
        case .medium: (4, 6)
        case .large: (6, 9)
        case .wide: (8, 9)
        }
    }
}

/// Type-erased `DashboardWidget`.
@MainActor
public struct WidgetType: Identifiable {
    public let kind: String
    public let displayName: String
    public let summary: String
    public let systemImage: String
    public let defaultSize: WidgetSize
    /// How small and large it may be resized, in grid cells.
    public let sizeLimits: GridLimits
    public let aiTasks: [AITask]
    public let defaultConfig: JSONValue
    public let configSchema: JSONValue
    public let hasSettings: Bool
    /// Decodes and re-encodes a config, throwing if it does not fit the widget's `Config`.
    public let normalize: (JSONValue) throws -> JSONValue
    public let content: (Binding<JSONValue>, WidgetContext) -> AnyView
    public let settings: (Binding<JSONValue>, WidgetContext) -> AnyView
    /// Sample-data rendering for galleries (nil: the widget has none; show a placeholder).
    public let preview: ((JSONValue) -> AnyView)?
    public let snapshot: (JSONValue, WidgetContext) async -> JSONValue

    public nonisolated var id: String { kind }

    /// A widget defined at runtime (declarative extensions) with no typed config.
    public init(
        kind: String, displayName: String, summary: String, systemImage: String, defaultSize: WidgetSize,
        sizeLimits: GridLimits = GridLimits(), aiTasks: [AITask] = [], preview: (() -> AnyView)? = nil,
        content: @escaping (WidgetContext) -> AnyView, snapshot: @escaping (WidgetContext) async -> JSONValue
    ) {
        self.preview = preview.map { make in { _ in make() } }
        self.kind = kind
        self.displayName = displayName
        self.summary = summary
        self.systemImage = systemImage
        self.defaultSize = defaultSize
        self.sizeLimits = sizeLimits
        self.aiTasks = aiTasks
        defaultConfig = .object([:])
        configSchema = ["type": "object", "properties": .object([:])]
        hasSettings = false
        normalize = { $0 }
        self.content = { _, context in content(context) }
        settings = { _, _ in AnyView(EmptyView()) }
        self.snapshot = { _, context in await snapshot(context) }
    }

    public init<W: DashboardWidget>(_ widget: W.Type) {
        kind = W.kind
        displayName = W.displayName
        summary = W.summary
        systemImage = W.systemImage
        defaultSize = W.defaultSize
        sizeLimits = W.sizeLimits
        aiTasks = W.aiTasks
        let fallback = W.defaultConfig
        defaultConfig = (try? JSONValue(encoding: fallback)) ?? .object([:])
        configSchema = W.configSchema
        hasSettings = W.Settings.self != EmptyView.self
        normalize = { raw in
            do { return try JSONValue(encoding: raw.decode(W.Config.self)) } catch let error as DecodingError {
                throw ToolError("Invalid \(W.kind) config: \(error.readableDescription)")
            }
        }
        func typed(_ raw: Binding<JSONValue>) -> Binding<W.Config> {
            Binding(
                get: { (try? raw.wrappedValue.decode(W.Config.self)) ?? fallback },
                set: { newValue in
                    if let encoded = try? JSONValue(encoding: newValue) { raw.wrappedValue = encoded }
                })
        }
        content = { raw, context in AnyView(W.content(config: typed(raw), context: context)) }
        settings = { raw, context in AnyView(W.settings(config: typed(raw), context: context)) }
        preview = W.Preview.self == EmptyView.self ? nil : { raw in
            AnyView(W.preview(config: (try? raw.decode(W.Config.self)) ?? fallback))
        }
        snapshot = { raw, context in
            await W.snapshot(config: (try? raw.decode(W.Config.self)) ?? fallback, context: context)
        }
    }
}
