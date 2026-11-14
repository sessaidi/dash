import Foundation
import Testing
@testable import ClaudeCodeKit

struct PlanLimitsTests {
    @Test func parsesUsageCredits() {
        let text = """
        What's contributing to your limits usage?   99%  Give "general-purpose" subagents a cheaper model
        f to fix 1 of 2 · d to day · w to week   Usage credits   █████▍                                            10%used
           $547.72 / $5,000.00 spent · Resets Dec 1 (Europe/Paris)   Esc to cancel
        """
        let limits = ClaudePlanLimits.parse(text)
        #expect(limits.meters == [.init(title: "Usage credits", percentUsed: 10, spent: 547.72, limit: 5000, resets: "Dec 1 (Europe/Paris)")])
    }

    @Test func parsesSessionAndWeeklyMeters() {
        let text = """
        Current session   ███████                 35% used   Resets 3pm (Europe/Paris)
        Current week (all models)   ██        12% used   Resets Nov 20, 9am (Europe/Paris)
        Current week (Opus)   █   4% used   Resets Nov 20, 9am (Europe/Paris)
        """
        let meters = ClaudePlanLimits.parse(text).meters
        #expect(meters.map(\.title) == ["Current session", "Current week (all models)", "Current week (Opus)"])
        #expect(meters.map(\.percentUsed) == [35, 12, 4])
        #expect(meters[0].resets == "3pm (Europe/Paris)")
        #expect(meters[1].resets == "Nov 20, 9am (Europe/Paris)")
    }

    @Test func rendersTerminalOutput() {
        let raw = Data("\u{1B}[1mUsage\u{1B}[3Ccredits\u{1B}[0m 10%used".utf8)
        #expect(TerminalSession.render(raw) == "Usage   credits 10%used")
    }
}
