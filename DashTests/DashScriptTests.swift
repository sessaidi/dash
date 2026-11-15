import DashKit
import Foundation
import Testing
@testable import Dash

/// DashQL statements: Dashii's and the agents' one way to work in Dash.
@MainActor
struct DashScriptTests {
    private func make(gate: @escaping (DashiiTool, JSONValue) async -> String? = { _, _ in nil }) throws -> (ExtensionHost, DashScript) {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "script-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        let tools = CoreTools.tools(host: host) + ViewContext.tools(host: host) + DashQL.tools(host: host) + host.availableTools
        return (host, DashScript(host: host, tools: tools, gate: gate))
    }

    @Test func statementsAndOptionsParse() {
        #expect(DashScript.statements("from pods | take 1\nwidget \"A; B\" read; # comment\n\nhelp") == ["from pods | take 1", "widget \"A; B\" read", "help"])
        var args = DashArgs("add note title=\"My note\" x=0 w=6 tags=[a, b] config={\"text\": \"hi there\"} on=true")
        #expect(args.word() == "add" && args.word() == "note")
        let options = args.options()
        #expect(options["title"] == "My note" && options["x"] == 0 && options["w"] == 6 && options["on"] == true)
        #expect(options["tags"] == ["a", "b"] && options["config"]?["text"] == "hi there")
    }

    @Test func buildsAPageAndDrivesItsWidgets() async throws {
        let (host, script) = try make()
        let result = await script.run("""
            page create "Writing" icon=doc.text
            page "Writing" add note title="Draft" x=0 y=0 w=8 h=6
            show page "Writing"
            from widgets | where title = "Draft" | select kind, w
            """)
        let steps = try #require(result.array)
        #expect(steps.count == 4 && steps.allSatisfy { $0["error"] == nil })
        #expect(steps[3]["result"]?["rows"]?.array?.first == ["kind": "note", "w": 8])
        let page = try #require(host.dashboard.pages().first { $0.name == "Writing" })
        #expect(host.selectedPageID == page.id)

        let read = await script.run("widget \"Draft\" read")
        #expect(read["result"]?["kind"] == "note")
        let missing = await script.run("widget \"Nope\" read")
        #expect(missing["error"]?.string?.contains("No widget") == true)
    }

    @Test func stopsAtTheFirstErrorAndExplains() async throws {
        let (_, script) = try make()
        let result = try #require(await script.run("from activity | take 1\nfrobnicate now\nhelp").array)
        #expect(result.count == 2 && result[1]["error"]?.string?.contains("Unknown verb") == true)
        let unknownTool = await script.run("tool no_such_tool a=1")
        #expect(unknownTool["error"]?.string?.contains("isn't available") == true)
        let help = await script.run("help")
        #expect(help["result"]?["tools"]?.array?.isEmpty == false)
    }

    @Test func everyCallPassesTheGate() async throws {
        var asked: [String] = []
        let (host, script) = try make { tool, _ in
            asked.append(tool.name)
            return tool.requiresApproval ? "The user declined this action." : nil
        }
        let note = try host.dashboard.add(kind: "note", title: "Keep me")
        let result = await script.run("widget \"Keep me\" remove")
        #expect(result["error"] == "The user declined this action.")
        #expect(asked == ["remove_widget"])
        #expect((try? host.dashboard.widget(note.id)) != nil)
    }

    @Test func reportsActionsAndPlansWithoutRunning() async throws {
        var (host, script) = try make()
        let ran = await script.run("page create \"Ops\" icon=bell")
        #expect(ran["actions"]?.array?.first?["tool"] == "create_page")
        #expect(ran["result"]?["name"] == "Ops")

        script.plan = true
        let planned = try #require(await script.run("""
            page create "Later" icon=bell
            page "Later" add note title="Hello" x=0 y=0 w=6 h=4
            widget "Hello" remove
            """).array)
        #expect(planned.map { $0["actions"]?.array?.compactMap { $0["tool"]?.string } ?? [] }.prefix(2) == [["create_page"], ["add_widget", "place_widget"]])
        #expect(planned.allSatisfy { $0["result"] == nil })
        #expect(!host.dashboard.pages().contains { $0.name == "Later" })
    }
}
