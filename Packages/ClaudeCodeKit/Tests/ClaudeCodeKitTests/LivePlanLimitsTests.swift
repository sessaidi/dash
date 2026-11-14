import Foundation
import Testing
@testable import ClaudeCodeKit

/// Talks to the real Claude Code; runs only with DASH_LIVE_USAGE=1.
struct LivePlanLimitsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_LIVE_USAGE"] == "1"))
    func readsTheRealPanel() async throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Dash/claude-status")
        let text = try TerminalSession.usagePanel(executable: Locator.claude()!, folder: folder)
        try text.write(toFile: NSTemporaryDirectory() + "dash-usage-panel.txt", atomically: true, encoding: .utf8)
        let limits = ClaudePlanLimits.parse(text)
        print("LIVE METERS:", limits.meters)
        #expect(!limits.meters.isEmpty)
    }
}
