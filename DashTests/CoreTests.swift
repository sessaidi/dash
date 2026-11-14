import DashKit
import Foundation
import Testing
@testable import Dash
import DashKitUI

@MainActor
struct DashboardStoreTests {
    private func host() throws -> ExtensionHost {
        try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                          extensions: ExtensionHost.builtInExtensions(), inMemory: true)
    }

    @Test func addMergesConfigOverDefaultsAndRejectsBadConfig() throws {
        let host = try host()
        host.dashboard.migrate()
        let note = try host.dashboard.add(kind: "note", config: ["text": "standup"])
        #expect(note.config == ["text": "standup"])
        #expect(note.size == .small)
        #expect(throws: ToolError.self) { try host.dashboard.add(kind: "note", config: ["text": 42]) }
        #expect(throws: ToolError.self) { try host.dashboard.add(kind: "no-such-kind") }
    }

    @Test func sectionsGroupRenameAndReleasePages() throws {
        let host = try host()
        host.dashboard.migrate()
        let ops = host.dashboard.createPage(name: "Ops")
        let reviews = host.dashboard.createPage(name: "Reviews")
        let team = host.dashboard.createSection(name: "Team")
        host.dashboard.movePage(ops.id, toSection: team.id)
        host.dashboard.movePage(reviews.id, toSection: team.id)
        #expect(host.dashboard.pages().filter { $0.sectionID == team.id }.map(\.name) == ["Ops", "Reviews"])
        host.dashboard.movePages(in: team.id, from: [1], to: 0)
        #expect(host.dashboard.pages().filter { $0.sectionID == team.id }.map(\.name) == ["Reviews", "Ops"])
        host.dashboard.renameSection(team.id, to: "  On-call ")
        #expect(host.dashboard.sections().map(\.name) == ["On-call"])
        host.dashboard.renameSection(team.id, to: "   ")
        #expect(host.dashboard.sections().map(\.name) == ["On-call"])
        // Deleting a section keeps its pages, back in the built-in section.
        host.dashboard.deleteSection(team.id)
        #expect(host.dashboard.sections().isEmpty)
        #expect(host.dashboard.pages().allSatisfy { $0.sectionID == nil })
        #expect(host.dashboard.pages().count == 3)
    }

    @Test func pagesCanBeDroppedBeforeAnother() throws {
        let host = try host()
        host.dashboard.migrate()
        let a = host.dashboard.createPage(name: "A")
        let b = host.dashboard.createPage(name: "B")
        let team = host.dashboard.createSection(name: "Team")
        host.dashboard.movePage(a.id, toSection: team.id)
        // Dropping B on A puts it just above A, in A's section.
        host.dashboard.movePage(b.id, toSection: team.id, before: a.id)
        #expect(host.dashboard.pages().filter { $0.sectionID == team.id }.map(\.name) == ["B", "A"])
        // Within one section, dropping on a row reorders.
        host.dashboard.movePage(a.id, toSection: team.id, before: b.id)
        #expect(host.dashboard.pages().filter { $0.sectionID == team.id }.map(\.name) == ["A", "B"])
    }

    @Test func moveReordersAndUpdatePatches() throws {
        let host = try host()
        host.dashboard.migrate()
        let a = try host.dashboard.add(kind: "note", title: "A")
        let b = try host.dashboard.add(kind: "note", title: "B")
        #expect(a.frame == GridFrame(x: 0, y: 0, w: 3, h: 4) && b.frame == GridFrame(x: 3, y: 0, w: 3, h: 4))
        try host.dashboard.place(b.id, x: 0, y: 0)
        #expect(host.dashboard.widgets().map(\.title) == ["B", "A"])
        #expect(try host.dashboard.widget(a.id).frame.y == 4)
        try host.dashboard.update(a.id, title: "A2", size: .wide, config: ["text": "hello"])
        let updated = try host.dashboard.widget(a.id)
        #expect(updated.title == "A2" && updated.size == .wide && updated.config == ["text": "hello"])
    }

    @Test func featuresDeclareTheirIntegrations() throws {
        let host = try host()
        let gitHub = FakeIntegration(id: "github")
        let pulls = FakeFeature(id: "pull-requests", requires: ["github"])
        let agents = FakeFeature(id: "agents", requires: ["atlassian"], optional: ["github"])
        host.install(forTesting: [gitHub, pulls, agents])
        #expect(pulls.layer == .feature && gitHub.layer == .integration)
        #expect(Set(host.features(using: "github").map(\.id)) == ["pull-requests", "agents", "marketplace"])
        #expect(host.features(using: "gcp").isEmpty)
        // A feature's tools stay hidden until its required integrations are connected.
        #expect(host.unmetRequirements(of: pulls) == ["github"])
        #expect(!host.availableTools.contains { $0.name == "pull-requests_run" })
        gitHub.isConnected = true
        #expect(host.unmetRequirements(of: pulls).isEmpty)
        #expect(host.availableTools.contains { $0.name == "pull-requests_run" })
    }

    @Test func coreToolsDriveTheDashboard() async throws {
        let host = try host()
        host.dashboard.migrate()
        let tools = CoreTools.tools(host: host)
        let add = try #require(tools.first { $0.name == "add_widget" })
        let added = try await add.run(["kind": "note", "title": "From Claude", "config": ["text": "hi"]])
        #expect(added["title"] == "From Claude")
        let list = try #require(tools.first { $0.name == "list_widgets" })
        #expect(try await list.run([:]).array?.count == 1)
        let update = try #require(tools.first { $0.name == "update_widget" })
        await #expect(throws: ToolError.self) { _ = try await update.run(["id": "not-a-uuid"]) }
    }
}
