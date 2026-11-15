import DashKit
import Foundation
import SwiftData
import Testing
@testable import Dash

/// Skills: know-how Dashii loads when a task calls for it.
@MainActor
struct SkillsTests {
    @Test func seedListUseSaveDelete() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "skills-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        DashDefaults.shared.removeObject(forKey: "skills.seeded")
        Skills.seed(in: host.context)
        #expect(Skills.named("bug-report", in: host.context)?.origin == "dash")
        let catalog = try #require(Skills.catalog(in: host.context))
        #expect(catalog.contains("bug-report:") && !catalog.contains("Investigate before writing"))

        let script = DashScript(host: host, tools: Skills.tools(host: host)) { _, _ in nil }
        let used = await script.run("skill use bug-report")
        #expect(used["result"]?["instructions"]?.string?.contains("Never file it in Jira") == true)

        let saved = await script.run(#"skill save release-notes when_to_use="Writing release notes" instructions="List the tickets. API_KEY=abc12345secret""#)
        #expect(saved["error"] == nil)
        let skill = try #require(Skills.named("release-notes", in: host.context))
        #expect(!skill.instructions.contains("abc12345secret"))  // sanitized

        skill.enabled = false
        #expect(await script.run("skill use release-notes")["error"] != nil)
        #expect(await script.run("skill delete release-notes")["error"] == nil)
        #expect(Skills.named("release-notes", in: host.context) == nil)
        #expect(DocKind(rawValue: "bug_report")?.outline.contains("Steps to reproduce") == true)
    }
}
