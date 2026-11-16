import Foundation
import Testing
@testable import Dash

/// The summary a fresh start is written from, and what the new conversation carries.
struct FreshStartTests {
    @Test func sourceKeepsMessagesAndShortensToolResults() {
        let entries = [
            ChatEntry(id: "1", kind: .user("Review PR 274")),
            ChatEntry(id: "2", kind: .tool(name: "dash", input: "github_get_pr number=274", result: String(repeating: "x", count: 5_000), isError: false)),
            ChatEntry(id: "3", kind: .thinking("hidden")),
            ChatEntry(id: "4", kind: .text("It has 1 approval.")),
        ]
        let source = FreshStart.source(entries)
        #expect(source.hasPrefix("User: Review PR 274") && source.contains("[tool dash] github_get_pr number=274"))
        #expect(source.contains("Dashii: It has 1 approval.") && !source.contains("hidden"))
        #expect(source.count < 1_200)
    }

    @Test func longConversationsKeepTheirStartAndEnd() {
        let entries = [ChatEntry(id: "0", kind: .user("The goal"))]
            + (1...400).map { ChatEntry(id: "\($0)", kind: .text("Step \($0) " + String(repeating: "y", count: 600))) }
        let source = FreshStart.source(entries)
        #expect(source.count <= FreshStart.sourceLimit + 100)
        #expect(source.hasPrefix("User: The goal") && source.contains("Step 400") && source.contains("left out"))
    }

    @Test func carryOverNamesTheEarlierConversation() {
        let text = FreshStart.carryOver("## Goal\nShip it", title: "PR 274")
        #expect(text.hasPrefix("<earlier-conversation title=\"PR 274\">") && text.contains("Ship it") && text.hasSuffix("</earlier-conversation>"))
    }
}
