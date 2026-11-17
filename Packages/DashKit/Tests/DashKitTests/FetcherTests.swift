import DashKitTesting
import Foundation
import SwiftUI
import Testing
@testable import DashKit

/// Fetchers: Dashii and agents ask an integration to fetch into the database by name.
@MainActor
struct FetcherTests {
    final class Wiki: DashExtension {
        let id = "wiki"
        let name = "Wiki"
        let systemImage = "book"
        let metadata = ExtensionMetadata(version: "1.0.0", summary: "Test.")
        var stored: [String] = []
        func settingsView() -> AnyView { AnyView(EmptyView()) }
        func start(host: any ExtensionContext) {}
        var fetchers: [DataFetcher] {
            [DataFetcher(name: "wiki.pages", summary: "Pages about a term.", properties: ["query": JSONSchema.string("Words.")], required: ["query"]) { [weak self] input in
                let query = input["query"]?.string ?? ""
                self?.stored.append(query)
                return ["stored": 1, "read_with": "knowledge search"]
            }]
        }
    }

    @Test func fetchRunsTheOwnersFetcherByName() async throws {
        let wiki = Wiki()
        let host = try TestHost([wiki])
        #expect(host.fetchers.map(\.name) == ["wiki.pages"])
        #expect(try await host.fetch("wiki.pages", ["query": "epg"]) == ["stored": 1, "read_with": "knowledge search"])
        #expect(wiki.stored == ["epg"])
        await #expect(throws: ToolError.self) { _ = try await host.fetch("jira.issues") }
        host.disabled = ["wiki"]
        #expect(host.fetchers.isEmpty)
    }

    @Test func toolsThatCallTheServiceAreNotForDashii() async throws {
        let read = DashiiTool(name: "wiki_page", description: "Reads the stored page.") { _ in "stored" }
        let live = DashiiTool(name: "wiki_api", description: "Calls the wiki.", properties: ["path": JSONSchema.string("Path.")], required: ["path"],
                              callsService: true) { _ in "live" }
        let post = DashiiTool(name: "wiki_post", description: "Posts.", writesRemotely: true) { _ in "posted" }
        #expect(read.isForDashii && !read.callsService)
        #expect(!live.isForDashii && live.callsService && !live.requiresApproval && live.inputSchema["required"] == ["path"])
        #expect(!post.isForDashii && !post.callsService && post.requiresApproval)
        #expect(try await live.run([:]) == "live")
    }
}
