import Foundation
import Testing
@testable import Dash

@Suite("Dashii blocks")
struct DashiiBlocksTests {
    @Test func shorthandBecomesADirective() {
        let source = "# Plan\n@dashii, can you check LAF-12?\n@Dashii: \"quoted\" too\ntext"
        #expect(DashiiBlocks.normalized(source) == "# Plan\n@Dashii(ask: \"can you check LAF-12?\")\n@Dashii(ask: \"\\\"quoted\\\" too\")\ntext")
        // Already a directive, or an @Ask: left alone.
        #expect(DashiiBlocks.normalized("@Dashii(ask: \"x\")\n@Ask(prompt: \"y\")") == "@Dashii(ask: \"x\")\n@Ask(prompt: \"y\")")
    }

    @Test func answeringWritesTheBodyAndKeepsTheRest() throws {
        let source = "# Plan\n\n@Dashii can you look at the workspaces for LAF-1234?\n\nAfter."
        let blocks = DashiiBlocks.blocks(in: source)
        #expect(blocks.map(\.ask) == ["can you look at the workspaces for LAF-1234?"])
        let answered = try DashiiBlocks.answering("workspaces for LAF-1234", with: "## Report\n\nAll green.", in: source)
        let block = try #require(DashiiBlocks.blocks(in: answered).first)
        #expect(block.id != nil && block.answer == "## Report\n\nAll green.")
        #expect(answered.hasPrefix("# Plan\n\n@Dashii(ask: \"can you look at the workspaces for LAF-1234?\", id: \(block.id!)) {\n  ## Report\n\n  All green.\n}"))
        #expect(answered.hasSuffix("}\n\nAfter."))

        // Asking again replaces the answer, by id, including nested components.
        let again = try DashiiBlocks.answering(block.id!, with: "@Callout(style: tip) {\n  New.\n}", in: answered)
        let updated = try #require(DashiiBlocks.blocks(in: again).first)
        #expect(updated.id == block.id && updated.answer == "@Callout(style: tip) {\n  New.\n}")
        #expect(again.hasSuffix("}\n\nAfter."))
        #expect(throws: (any Error).self) { try DashiiBlocks.answering("nothing like it", with: "x", in: source) }
    }

    @Test func renderedAsAComponent() {
        let document = NoteDocument("@Dashii can you summarise?")
        guard case .component(let component)? = document.blocks.first else { Issue.record("not a component"); return }
        #expect(component.name == "Dashii" && component.arguments["ask"] == "can you summarise?")
    }
}
