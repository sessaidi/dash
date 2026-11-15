import DashKit
import Foundation
import Testing
@testable import Dash

/// Dashii suggesting a layout as a draft page.
@MainActor
struct LayoutSuggestionTests {
    @Test func draftPageIsBuiltThenKeptOrDiscarded() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "layout-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        let tools = CoreTools.tools(host: host)
        func run(_ name: String, _ input: JSONValue = .object([:])) async throws -> JSONValue {
            try await #require(tools.first { $0.name == name }).run(input)
        }

        let context = try await run("layout_context")
        #expect(context["widget_types"]?.array?.contains { $0["kind"] == "note" } == true)
        #expect(context["pages"]?.array?.isEmpty == false && context["grid"] != nil)

        let page = try await run("suggest_layout", ["name": "Morning", "icon": "sun.max", "rationale": "Standup first."])
        let id = try #require(page["id"]?.string.flatMap(UUID.init(uuidString:)))
        #expect(page["draft"] == true && host.selectedPageID == id)
        _ = try await run("add_widget", ["kind": "note", "page_id": .string(id.uuidString)])
        #expect(host.dashboard.widgets(on: id).count == 1)
        #expect(try host.dashboard.page(id).draftRationale == "Standup first.")

        try host.dashboard.keepDraft(id)
        #expect(try host.dashboard.page(id).isDraft == false)

        let other = try await run("suggest_layout", ["name": "On-call", "rationale": "Incidents."])
        let otherID = try #require(other["id"]?.string.flatMap(UUID.init(uuidString:)))
        try host.dashboard.deletePage(otherID)
        #expect(!host.dashboard.pages().contains { $0.id == otherID })
    }
}
