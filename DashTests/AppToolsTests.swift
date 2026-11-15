import DashKit
import Foundation
import SwiftData
import Testing
@testable import Dash

/// Dashii working the rest of the app: sidebar, plugins, automation, agents, screens.
@MainActor
@Suite(.serialized)
struct AppToolsTests {
    private func make() throws -> (ExtensionHost, DashScript) {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "apptools-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        AutomationStore.shared.host = host
        let tools = CoreTools.tools(host: host) + DashQL.tools(host: host) + AppTools.tools(host: host) + host.availableTools
        return (host, DashScript(host: host, tools: tools) { _, _ in nil })
    }

    private func ok(_ result: JSONValue) -> Bool {
        (result.array ?? [result]).allSatisfy { $0["error"] == nil }
    }

    @Test func organisesTheSidebar() async throws {
        let (host, script) = try make()
        let result = await script.run("""
            page create "On-call" icon=bell
            page create "Releases" icon=bell
            section create "Ops"
            page "On-call" move section="Ops"
            page "Releases" move section="Ops" before="On-call"
            page "On-call" home on
            """)
        #expect(ok(result), "\(result)")
        let ops = try #require(host.dashboard.sections().first { $0.name == "Ops" })
        let inOps = host.dashboard.pages().filter { $0.sectionID == ops.id }.sorted { $0.order < $1.order }.map(\.name)
        #expect(inOps == ["Releases", "On-call"])
        #expect(host.dashboard.pages().first { $0.name == "On-call" }?.showsHome == true)
        let sidebar = await script.run("sidebar")
        #expect(sidebar["result"]?.array?.contains { $0["section"] == "Ops" } == true)
        #expect(ok(await script.run("section delete \"Ops\"")))
        #expect(host.dashboard.pages().first { $0.name == "On-call" }?.sectionID == nil)
    }

    @Test func automationAgentsAndPlugins() async throws {
        let (host, script) = try make()
        let result = await script.run("""
            command save standup prompt="Prepare my standup for {{args}}" summary="Standup notes"
            hook create name="Morning" trigger={"schedule":{"time":"09:00","weekdays":[2,3,4,5,6]}} action={"notify":{"title":"Hi","body":"Coffee"}}
            hook off "Morning"
            agent create "Release watcher" role="Release manager" instructions="Check the EU train" every_minutes=30
            agent "Release watcher" set every_minutes=60
            """)
        #expect(ok(result), "\(result)")
        #expect(AutomationStore.shared.savedCommand("standup")?.prompt == "Prepare my standup for {{args}}")
        let hooks = try host.context.fetch(FetchDescriptor<AutomationHook>())
        #expect(hooks.count == 1 && hooks[0].enabled == false && hooks[0].trigger == .schedule(time: "09:00", weekdays: [2, 3, 4, 5, 6]))
        let agents = try host.context.fetch(FetchDescriptor<CustomAgent>())
        #expect(agents.first?.everyMinutes == 60 && agents.first?.role == "Release manager" && agents.first?.canAct == false)

        let shell = await script.run(#"hook create name="Bad" trigger={"launch":{}} action={"shell":{"command":"rm -rf ~"}}"#)
        #expect(shell["error"]?.string?.contains("made by the user") == true)

        let notes = try #require(host.extensions.first { $0.id == "notes" })
        #expect(ok(await script.run("plugin \"notes\" off")))
        #expect(!host.isEnabled(notes))
        #expect(ok(await script.run("plugin \"notes\" on")))
        #expect(host.isEnabled(notes))
        #expect(await script.run("open nowhere")["error"] != nil)
    }
}
