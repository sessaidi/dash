import DashKit
import Foundation
import Testing
@testable import Dash

/// Questions and layouts Dashii draws in the chat.
@MainActor
struct ChatComponentsTests {
    private func make() throws -> (ExtensionHost, ChatSession) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "components-\(UUID())")!)
        // Picking a layout messages Dashii: never reach a real Claude from tests.
        settings.claudePath = "/usr/bin/false"
        let host = try ExtensionHost(settings: settings, extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        return (host, ChatSession(host: host))
    }

    @Test func askUserDrawsAQuestion() async throws {
        let (_, chat) = try make()
        let tool = try #require(chat.componentTools.first { $0.name == "ask_user" })
        _ = try await tool.run(["question": "What is this page for?", "options": ["On-call", "Release manager", "Daily work"]])
        guard case .choices(let choices)? = chat.transcript.last?.kind else { Issue.record("no question drawn"); return }
        #expect(choices.options.count == 3 && choices.answer == nil && choices.allowOther)
        await #expect(throws: ToolError.self) { try await tool.run(["question": "?", "options": []]) }
    }

    @Test func pickingALayoutBuildsThePage() async throws {
        let (host, chat) = try make()
        let tool = try #require(chat.componentTools.first { $0.name == "propose_layouts" })
        _ = try await tool.run([
            "page_name": "Writing", "icon": "doc.text",
            "options": [
                ["title": "Focus", "rationale": "One big note.", "widgets": [["kind": "note", "title": "Draft", "x": 0, "y": 0, "w": 12, "h": 10]]],
                ["title": "Split", "rationale": "Two notes.", "widgets": [
                    ["kind": "note", "title": "Left", "x": 0, "y": 0, "w": 6, "h": 8],
                    ["kind": "note", "title": "Right", "x": 20, "y": 0, "w": 6, "h": 8]]],
            ],
        ])
        guard case .layouts(let proposal)? = chat.transcript.last?.kind else { Issue.record("no layouts drawn"); return }
        #expect(proposal.options.map(\.title) == ["Focus", "Split"])
        #expect(proposal.options[1].widgets[1].x == 6)  // kept inside the 12 columns

        chat.choose("option-2", in: proposal.id)
        guard case .layouts(let chosen)? = chat.transcript.first(where: { $0.id == proposal.id })?.kind else { return }
        let pageID = try #require(chosen.pageID)
        #expect(chosen.chosen == "option-2" && host.selectedPageID == pageID)
        let widgets = host.dashboard.widgets(on: pageID)
        #expect(widgets.map(\.title).sorted() == ["Left", "Right"])
        #expect(widgets.first { $0.title == "Right" }?.gridX == 6)
        chat.stop()

        await #expect(throws: ToolError.self) {
            try await tool.run(["page_name": "X", "options": [["title": "A", "rationale": "", "widgets": [["kind": "nope", "title": "?", "x": 0, "y": 0, "w": 4, "h": 4]]]]])
        }
    }

    @Test func reworkingAPageReplacesItsWidgets() async throws {
        let (host, chat) = try make()
        let page = host.dashboard.createPage(name: "On-call", systemImage: "bell")
        _ = try host.dashboard.add(kind: "note", title: "Old", page: page.id)
        let tool = try #require(chat.componentTools.first { $0.name == "propose_layouts" })
        _ = try await tool.run(["page_name": "On-call", "page_id": .string(page.id.uuidString), "options": [
            ["title": "Pods first", "rationale": "", "widgets": [["kind": "note", "title": "New", "x": 0, "y": 0, "w": 12, "h": 6]]],
            ["title": "Split", "rationale": "", "widgets": [["kind": "note", "title": "Other", "x": 0, "y": 0, "w": 6, "h": 6]]],
        ]])
        guard case .layouts(let proposal)? = chat.transcript.last?.kind else { Issue.record("no layouts"); return }
        #expect(proposal.reworks && proposal.pageID == page.id)
        chat.choose("option-1", in: proposal.id)
        chat.stop()
        #expect(host.dashboard.widgets(on: page.id).map(\.title) == ["New"])
        #expect(host.dashboard.pages().filter { $0.name == "On-call" }.count == 1)
    }
}
