import Observation
import SwiftUI

/// Something Dashii can do with a widget on screen: search it, filter it, select a row, jump to a
/// date. Declared by the widget type (`DashboardWidget.actions`), handled by its visible view
/// (`handlesWidgetActions`). Actions only change what the widget shows; they never write
/// remotely.
public struct WidgetAction: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, properties: [String: JSONValue] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        inputSchema = ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    public var json: JSONValue { ["name": .string(name), "description": .string(description), "input_schema": inputSchema] }
}

/// One placed widget's live link to Dashii: the action handler its visible view registered,
/// the UI state it reports (filter, selection, visible range), and when Dashii last looked at it.
@MainActor
@Observable
public final class WidgetLiveState {
    public fileprivate(set) var handler: (@MainActor (String, JSONValue) async throws -> JSONValue)?
    public fileprivate(set) var state: JSONValue = .null
    /// The item the user selected in the widget (a ticket, a PR, a pod), as a row: other widgets
    /// can filter on it with `$selected("Title").field`. Temporary, like the rest of the UI state.
    public fileprivate(set) var selection: JSONValue?
    /// Set by Dash while Dashii reads or drives the widget, so the card can show it.
    public var attention: Date?

    public init() {}

    /// Runs an action on the visible view.
    public func perform(_ name: String, input: JSONValue) async throws -> JSONValue {
        guard let handler else { throw ToolError("The widget isn't on screen; open its page first (view_show).") }
        return try await handler(name, input)
    }
}

extension EnvironmentValues {
    /// Set by Dash on each widget's content.
    @Entry public var widgetLive: WidgetLiveState? = nil
}

extension View {
    /// Handles the widget type's `actions` while this view is on screen. Return what changed
    /// (for Dashii), or throw a `ToolError`.
    public func handlesWidgetActions(_ handler: @escaping @MainActor (String, JSONValue) async throws -> JSONValue) -> some View {
        modifier(WidgetActionsModifier(handler: handler))
    }

    /// Reports what the widget shows right now beyond its config (search text, selection,
    /// visible range…), included when Dashii reads the widget.
    public func reportsWidgetState(_ state: JSONValue) -> some View {
        modifier(WidgetStateModifier(state: state))
    }

    /// Publishes the item the user selected (nil when none), as a row with the same fields as the
    /// widget's dataset: linked widgets filter on it.
    public func reportsSelection(_ row: JSONValue?) -> some View {
        modifier(WidgetSelectionModifier(row: row))
    }
}

private struct WidgetActionsModifier: ViewModifier {
    let handler: @MainActor (String, JSONValue) async throws -> JSONValue
    @Environment(\.widgetLive) private var live

    func body(content: Content) -> some View {
        content
            .onAppear { live?.handler = handler }
            .onDisappear { live?.handler = nil }
    }
}

private struct WidgetStateModifier: ViewModifier {
    let state: JSONValue
    @Environment(\.widgetLive) private var live

    func body(content: Content) -> some View {
        content
            .onChange(of: state, initial: true) { live?.state = state }
            .onDisappear { live?.state = .null }
    }
}

private struct WidgetSelectionModifier: ViewModifier {
    let row: JSONValue?
    @Environment(\.widgetLive) private var live

    func body(content: Content) -> some View {
        content
            .onChange(of: row, initial: true) { live?.selection = row }
            .onDisappear { live?.selection = nil }
    }
}
