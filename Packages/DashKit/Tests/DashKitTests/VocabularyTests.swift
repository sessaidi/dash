import Foundation
import Testing
@testable import DashKit

/// What plugins tell DashQL: dataset aliases, statements, and which DashKit they need.
@MainActor
struct VocabularyTests {
    @Test func aliasesReachTheDataset() async throws {
        let jira = QueryDataset(name: "jira", aliases: ["Tickets"], summary: "Tickets") { _ in [["key": "KAN-1"]] }
        let result = try await QueryEngine(datasets: [jira]).run("from tickets")
        #expect(result.rows.count == 1)
        #expect(jira.schema["aliases"] == ["tickets"])
    }

    @Test func verbsDescribeTheirUsage() {
        let verb = DashQLVerb("Ticket", "Follow", tool: "jira_follow", arguments: ["key"], summary: "Follow a ticket.")
        #expect(verb.keyword == "ticket" && verb.action == "follow")
        #expect(verb.usage == "ticket follow <key> [key=value…]")
    }

    @Test func pluginsMustTargetThisMajor() {
        #expect(DashKitInfo.incompatibility(minimum: "\(DashKitInfo.major).0.0") == nil)
        #expect(DashKitInfo.incompatibility(minimum: "1.5.0")?.contains("Marketplace") == true)
        #expect(DashKitInfo.incompatibility(minimum: "\(DashKitInfo.major + 1).0.0")?.contains("Update Dash") == true)
        #expect(DashKitInfo.incompatibility(minimum: nil) != nil)
    }
}
