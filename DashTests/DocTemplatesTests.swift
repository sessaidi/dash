import DashKit
import Foundation
import Testing
@testable import Dash

/// Documents Dashii writes from what Dash knows.
@MainActor
struct DocTemplatesTests {
    @Test func everyKindHasAnOutlineSourcesAndRules() async throws {
        for kind in DocKind.allCases {
            let template = try await DocKind.tool.run(["kind": .string(kind.rawValue)])
            #expect(template["outline"]?.string?.hasPrefix("# ") == true, "\(kind)")
            #expect(template["sources"]?.string?.isEmpty == false && template["rules"]?.string?.contains("verified") == true)
        }
        await #expect(throws: ToolError.self) { try await DocKind.tool.run(["kind": "novel"]) }
        #expect(DocKind.runbook.prompt(topic: " pods crash ").contains("doc_template with kind runbook"))
        #expect(DocKind.dailyNote.prompt(topic: "").contains("daily note."))
    }

    @Test func notesOfferTheTool() throws {
        let notes = NotesExtension()
        #expect(notes.tools.first?.name == "doc_template")
    }
}
