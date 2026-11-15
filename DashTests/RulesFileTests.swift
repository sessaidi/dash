import DashKit
import Foundation
import Testing
@testable import Dash

/// Rules as Markdown files in an extension's bundle, and Dashii reading them.
@MainActor
struct RulesFileTests {
    @Test func loadsRulesFromABundleFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Rules"), withIntermediateDirectories: true)
        try "- Prefer dashql `pods`.\n".write(to: root.appending(path: "Rules/kubernetes.md"), atomically: true, encoding: .utf8)
        try "  \n".write(to: root.appending(path: "empty.rules.md"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: root))
        #expect(RulesFile.load(id: "kubernetes", bundle: bundle) == "- Prefer dashql `pods`.")
        #expect(RulesFile.load(id: "empty", bundle: bundle) == nil)
        #expect(RulesFile.load(id: "missing", bundle: bundle) == nil)
    }

    @Test func dashiiReadsRulesBeforeProposing() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "rules-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        AutomationStore.shared.host = host
        let script = DashScript(host: host, tools: AppTools.tools(host: host)) { _, _ in nil }
        #expect(await script.run("rules global")["result"]?["customized"] == false)
        #expect(await script.run("rules global text=\"Answer in English.\"")["error"] == nil)
        let shown = await script.run("rules global")
        #expect(shown["result"]?["in_use"] == "- Answer in English." && shown["result"]?["customized"] == true)
        AutomationStore.shared.resetRules("global")
    }
}
