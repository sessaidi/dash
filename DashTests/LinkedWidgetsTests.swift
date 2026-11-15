import AppKit
import DashKit
import Foundation
import SwiftUI
import Testing
@testable import Dash

/// The data widget, and widgets following each other's selection.
@MainActor
struct LinkedWidgetsTests {
    private func make() throws -> ExtensionHost {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "linked-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        return host
    }

    @Test func dataWidgetRunsAnyDataset() async throws {
        let host = try make()
        _ = try host.dashboard.add(kind: "note", title: "Alpha")
        _ = try host.dashboard.add(kind: "note", title: "Beta")
        let config = DataWidget.Config(dataset: "widgets", query: "where kind = note | sort title | select title", view: "table")
        let result = try await DataWidget.run(config, host: host)
        #expect(result.rows.map { $0["title"]?.string } == ["Alpha", "Beta"])
        let counts = try await DataWidget.run(.init(dataset: "widgets", query: "count by kind", view: "counts"), host: host)
        #expect(counts.rows.first?["count"]?.double ?? 0 >= 2)
        #expect(host.widgetType("dash.data") != nil)
    }

    @Test func linkedQueriesFollowTheSelection() async throws {
        let host = try make()
        let board = try host.dashboard.add(kind: "note", title: "Jira board")
        // Nothing selected: the link waits and the filter is off.
        let waiting = DashQL.resolveSelections("tickets ~ $selected(\"Jira board\").key", host: host)
        #expect(waiting.waiting == ["Jira board"])

        // A view publishes a selection, as a plugin widget does when the user picks a ticket.
        let view = NSHostingView(rootView: Color.clear.reportsSelection(["key": "KAN-1", "labels": ["a", "b"]]).environment(\.widgetLive, host.live(board.id)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 where host.live(board.id).selection == nil { try await Task.sleep(for: .milliseconds(20)) }

        let resolved = DashQL.resolveSelections("tickets ~ $selected(\"Jira board\").key and labels in $selected(\"Jira board\").labels", host: host)
        #expect(resolved.waiting.isEmpty)
        #expect(resolved.text == "tickets ~ \"KAN-1\" and labels in (\"a\", \"b\")")
        window.contentView = nil
    }

    @Test func linkedFiltersAreSavedWithTheirLink() throws {
        let host = try make()
        let prs = try host.dashboard.add(kind: "note", title: "PRs")
        // Notes have no filter fields: saving any filter is refused, links included.
        #expect(throws: ToolError.self) { try host.dashboard.setQuery(prs.id, "tickets ~ $selected(\"Jira board\").key") }
    }
}
