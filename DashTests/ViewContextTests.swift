import DashKit
import Foundation
import Testing
@testable import Dash

@MainActor
@Suite("View context")
struct ViewContextTests {
    func host() throws -> ExtensionHost {
        try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "view-\(UUID())")!),
                          extensions: ExtensionHost.builtInExtensions(), inMemory: true)
    }

    func tool(_ name: String, _ host: ExtensionHost) throws -> ClaudeTool {
        try #require(ViewContext.tools(host: host).first { $0.name == name })
    }

    @Test func summaryNamesTheOpenNote() throws {
        let host = try host()
        let notes = try #require(host.ext(NotesExtension.self))
        let parent = try notes.store.create(title: "Guides \(UUID().uuidString.prefix(4))")
        let child = try notes.store.createChild(of: parent, title: "gcloud")
        defer { try? notes.store.delete(parent) }
        host.mainView = "notes"
        #expect(ViewContext.summary(host: host) == "Notes, no note open.")
        notes.openNote = child.title
        notes.openNoteEditing = false
        let summary = ViewContext.summary(host: host)
        #expect(summary.contains("“gcloud” is open, a sub-note of “\(parent.title)”, in preview"))
    }

    @Test func showOpensNotesAndPages() async throws {
        let host = try host()
        let notes = try #require(host.ext(NotesExtension.self))
        let note = try notes.store.create(title: "Shown \(UUID().uuidString.prefix(4))")
        defer { try? notes.store.delete(note) }
        _ = try await tool("view_show", host).run(["note": .string(note.title)])
        #expect(host.mainView == "notes" && notes.openRequest == note.title)
        await #expect(throws: (any Error).self) { try await tool("view_show", host).run(["note": "Missing note"]) }

        let create = try #require(CoreTools.tools(host: host).first { $0.name == "create_page" })
        _ = try await create.run(["name": "On-call"])
        let page = try #require(host.dashboard?.pages().first { $0.name == "On-call" })
        _ = try await tool("view_show", host).run(["page": .string(page.name.lowercased())])
        #expect(host.mainView == "page" && host.dashboard?.currentPageID == page.id)
        #expect(ViewContext.summary(host: host).hasPrefix("The page “\(page.name)”"))
        let current = try await tool("view_current", host).run([:])
        #expect(current["view"] == "page" && current["page"]?["name"] == .string(page.name))
    }
}
