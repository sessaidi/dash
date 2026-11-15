import Foundation
import Testing
@testable import ClaudeCodeKit

struct UsageReportTests {
    @Test func parsesWindowsTipsAndTopEntries() {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        What's contributing to your limits usage?
        Approximate · sessions on this machine only · shares overlap

        Last 24h · 779 requests · 7 sessions
          98%  Give "general-purpose" subagents a cheaper model
          77%  Start fresh when you switch tasks · run /clear
          Top skills: /claude-api 1%
          Top subagents: general-purpose 19%, Explore 1%

        Last 7d · 1,576 requests · 8 sessions
          40%  Stop sessions you no longer need · some ran 8 hours or more
          Top MCP servers: plugin:atlassian:atlassian 2%
        """
        let report = ClaudeUsageReport.parse(text)
        #expect(report.plan == "You are currently using your subscription to power your Claude Code usage")
        #expect(report.windows.map(\.label) == ["Last 24h", "Last 7d"])
        #expect(report.windows[0].requests == 779 && report.windows[0].sessions == 7)
        #expect(report.windows[1].requests == 1576)
        #expect(report.windows[0].tips.map(\.percent) == [98, 77])
        #expect(report.windows[0].tips[1].text == "Start fresh when you switch tasks · run /clear")
        #expect(report.windows[0].top["subagents"] == [.init(percent: 19, text: "general-purpose"), .init(percent: 1, text: "Explore")])
        #expect(report.windows[1].top["MCP servers"]?.first?.text == "plugin:atlassian:atlassian")
    }

    @Test func unknownTextYieldsAnEmptyReport() {
        let report = ClaudeUsageReport.parse("something else entirely")
        #expect(report.windows.isEmpty)
    }

    @Test func decodesAuthStatus() throws {
        let json = #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max", "email": "a@b.c", "extra": 1}"#
        let status = try JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(json.utf8))
        #expect(status.loggedIn && status.subscriptionType == "max")
    }
}
