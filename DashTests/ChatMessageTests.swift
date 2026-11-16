import Foundation
import Testing
@testable import Dash

/// Dashii's messages render like notes, tables included, and copy cleanly.
struct ChatMessageTests {
    @Test func aTableRightUnderABoldLineIsATable() {
        let text = "**Clean**\n| Worktree | Status |\n|---|---|\n| .worktree/KAN-1 | Up to date |\n\nDone."
        let blocks = NoteDocument(ChatMessageText.prepared(text)).blocks
        #expect(blocks.contains { if case .table(let header, let rows) = $0 { header.map { String($0.characters) } == ["Worktree", "Status"] && rows.count == 1 } else { false } })
    }

    @Test func plainTextDropsTheMarks() {
        #expect(CopyMenu.plain("## Title\n**Bold** and `code`") == "Title\nBold and code")
    }
}
