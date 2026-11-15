import DashKit
import Foundation
import SwiftData
import Testing
@testable import Dash

/// "Always Allow": kept in the database, skipped for risky tools, revocable.
@MainActor
struct PermissionTests {
    @Test func alwaysAllowIsRememberedPerKey() async throws {
        let container = try ExtensionHost.makeContainer(models: [], inMemory: true)
        let center = PermissionCenter()
        center.store = container.mainContext
        let create = DashiiTool(name: "notes_create", description: "", requiresApproval: true) { _ in nil }
        let key = try #require(PermissionCenter.rememberKey("dashii", tool: create))

        let first = Task { await center.ask(PermissionPrompt(title: "Dashii wants to run notes_create", message: "", input: ["title": "BILL"], remember: key)) }
        while center.current == nil { await Task.yield() }
        #expect(center.current?.input?["title"] == "BILL")
        center.resolve(true, always: true)
        #expect(await first.value)

        // Asked again: answered from the database, no prompt.
        #expect(await center.ask(PermissionPrompt(title: "again", message: "", remember: key)))
        #expect(center.current == nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<PermissionGrant>()).map(\.label) == ["Dashii wants to run notes_create"])

        // Revoked: asks again.
        for grant in try container.mainContext.fetch(FetchDescriptor<PermissionGrant>()) { container.mainContext.delete(grant) }
        #expect(!center.isGranted(key))
    }

    @Test func riskyToolsAlwaysAsk() {
        func key(_ name: String, remote: Bool = false) -> String? {
            PermissionCenter.rememberKey("dashii", tool: DashiiTool(name: name, description: "", requiresApproval: true, writesRemotely: remote) { _ in nil })
        }
        #expect(key("notes_create") == "dashii:tool:notes_create")
        #expect(key("note_delete") == nil && key("docker_exec") == nil && key("docker_prune") == nil)
        #expect(key("jira_add_comment", remote: true) == nil)
    }
}
