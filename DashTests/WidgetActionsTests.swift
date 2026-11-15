import AppKit
import DashKit
import Foundation
import SwiftUI
import Testing
@testable import Dash

/// A widget with a search box Dashii can fill.
@MainActor
private struct SearchWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {}
    static let kind = "test.search"
    static let displayName = "Search"
    static let summary = "A searchable list."
    static let systemImage = "magnifyingglass"
    static let defaultConfig = Config()
    static let configSchema: JSONValue = ["type": "object"]
    static let actions = [WidgetAction(name: "search", description: "Search the list.", properties: ["text": JSONSchema.string("Text.")], required: ["text"])]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View { SearchView() }

    struct SearchView: View {
        @State private var query = ""
        var body: some View {
            Text(query)
                .reportsWidgetState(["query": .string(query)])
                .handlesWidgetActions { name, input in
                    guard name == "search", let text = input["text"]?.string else { throw ToolError("Unknown action.") }
                    query = text
                    return ["searched": .string(text)]
                }
        }
    }
}

@MainActor
private final class SearchFeature: DashExtension {
    let id = "searchfeature"
    let name = "Search"
    let systemImage = "magnifyingglass"
    var widgets: [WidgetType] { [WidgetType(SearchWidget.self)] }
}

@MainActor
struct WidgetActionsTests {
    @Test func dashiiReadsAndDrivesAWidgetOnScreen() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "actions-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions() + [SearchFeature()], inMemory: true)
        host.dashboard.migrate()
        let record = try host.dashboard.add(kind: "test.search")
        let tools = CoreTools.tools(host: host)
        func run(_ name: String, _ input: JSONValue) async throws -> JSONValue {
            try await #require(tools.first { $0.name == name }).run(input)
        }

        // Off screen: Dashii learns what it could do, and is told to open the page.
        let offscreen = try await run("read_widget", ["id": .string(record.id.uuidString)])
        #expect(offscreen["type"]?["summary"] == "A searchable list.")
        #expect(offscreen["actions"]?.array?.first?["name"] == "search")
        #expect(offscreen["on_screen"] == false)
        await #expect(throws: ToolError.self) { try await run("widget_act", ["id": .string(record.id.uuidString), "action": "search", "input": ["text": "x"]]) }

        // On screen: the action runs in the view and its UI state comes back.
        let view = NSHostingView(rootView: SearchWidget.SearchView().environment(\.widgetLive, host.live(record.id)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 where host.live(record.id).handler == nil { try await Task.sleep(for: .milliseconds(20)) }

        let result = try await run("widget_act", ["id": .string(record.id.uuidString), "action": "search", "input": ["text": "crash"]])
        #expect(result["result"]?["searched"] == "crash")
        #expect(result["ui_state"]?["query"] == "crash")
        #expect(host.live(record.id).attention != nil)
        await #expect(throws: ToolError.self) { try await run("widget_act", ["id": .string(record.id.uuidString), "action": "delete_everything"]) }
        window.contentView = nil
    }
}
