import DashKit
import Foundation
import Testing
@testable import Dash

/// DashQL: parse, filter, sort, project, summarise, join; and Dash's own datasets.
@MainActor
struct DashQLTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

    private var pods: QueryDataset {
        QueryDataset(name: "pods", summary: "Pods", fields: [.init("name"), .init("namespace", aliases: ["ns"]), .init("status"), .init("restarts", "number"),
                                                             .init("started", "date"), .init("labels", "list")]) { _ in
            [
                ["name": "api-1", "namespace": "papi-eu", "status": "CrashLoopBackOff", "restarts": 12, "started": "2026-11-15T10:00:00Z", "labels": ["app:api", "tier:web"], "owner": ["login": "sadik"]],
                ["name": "api-2", "namespace": "papi-eu", "status": "Running", "restarts": 0, "started": "2026-11-10T10:00:00Z", "labels": ["app:api"]],
                ["name": "worker-1", "namespace": "papi-us", "status": "Error", "restarts": 4, "started": "2026-11-15T11:30:00Z", "labels": ["app:worker"]],
                ["name": "db-0", "namespace": "data", "status": "Running", "restarts": 1, "started": "2026-10-01T00:00:00Z", "labels": []],
            ]
        }
    }

    private var tickets: QueryDataset {
        QueryDataset(name: "jira", summary: "Tickets", fields: [.init("key"), .init("summary"), .init("assignee")]) { _ in
            [["key": "LAF-1", "summary": "Crash on start", "assignee": "Sadik"], ["key": "LAF-2", "summary": "Docs", "assignee": "Alex"]]
        }
    }

    private var prs: QueryDataset {
        QueryDataset(name: "prs", summary: "PRs", fields: [.init("title"), .init("tickets", "list")]) { _ in
            [["title": "Fix crash", "tickets": ["LAF-1"]], ["title": "Also LAF-1", "tickets": ["laf-1", "LAF-9"]], ["title": "Nothing", "tickets": []]]
        }
    }

    private func engine() -> QueryEngine { QueryEngine(datasets: [pods, tickets, prs], me: ["sadik"], now: now) }

    private func names(_ query: String) async throws -> [String] {
        try await engine().run(query).rows.compactMap { $0["name"]?.string }
    }

    @Test func pipelineFiltersSortsAndProjects() async throws {
        #expect(try await names("from pods | where namespace = \"papi-eu\" and restarts > 3") == ["api-1"])
        #expect(try await names("from pods | sort -restarts | take 2") == ["api-1", "worker-1"])
        #expect(try await names("from pods where status in (\"Error\", \"CrashLoopBackOff\") | sort name") == ["api-1", "worker-1"])
        #expect(try await names("from pods | where restarts between 1 and 4 | sort restarts") == ["db-0", "worker-1"])
        #expect(try await names("from pods | where name =~ \"^api-\\\\d$\" and not status = Running") == ["api-1"])
        let projected = try await engine().run("from pods | where ns = papi-us | select name as pod, restarts")
        #expect(projected.rows == [["pod": "worker-1", "restarts": 4]])
    }

    @Test func shorthandDatesListsAndMe() async throws {
        #expect(try await names("pods ns:papi status:crash,error restarts>3") == ["api-1", "worker-1"])
        #expect(try await names("pods -status:Running ns:papi-eu") == ["api-1"])
        #expect(try await names("from pods | where started > -6h | sort name") == ["api-1", "worker-1"])
        #expect(try await names("from pods | where started < 2026-11-01") == ["db-0"])
        #expect(try await names("from pods | where labels ~ worker") == ["worker-1"])
        #expect(try await names("from pods | where owner.login = me") == ["api-1"])
        #expect(try await names("pods \"tier:web\"") == ["api-1"])
    }

    @Test func summariseDistinctAndJoin() async throws {
        let counts = try await engine().run("from pods | count by namespace").rows
        #expect(counts.first == ["namespace": "papi-eu", "count": 2])
        let stats = try await engine().run("from pods | summarize count(), max(restarts) as worst, avg(restarts) by status | sort -worst").rows
        #expect(stats.first?["worst"] == 12 && stats.first?["status"] == "CrashLoopBackOff")
        #expect(try await engine().run("from pods | distinct namespace").rows.count == 3)

        let joined = try await engine().run("from jira where assignee = me | join prs on key = tickets | select key, prs.title").rows
        #expect(joined == [["key": "LAF-1", "prs.title": ["Fix crash", "Also LAF-1"]]])
    }

    @Test func errorsSayWhatWasExpected() async throws {
        await #expect(throws: QueryError.self) { try await engine().run("from nowhere") }
        await #expect(throws: QueryError.self) { try await engine().run("from pods | frobnicate") }
        await #expect(throws: QueryError.self) { try await engine().run("from pods | where restarts >") }
        await #expect(throws: QueryError.self) { try await engine().run("") }
    }

    @Test func dashDatasetsAndTheTool() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dashql-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        let note = try host.dashboard.add(kind: "note", title: "Runbook links")
        host.activity.emit("pr.opened", source: "pull-requests", title: "New PR api#1")
        let tool = try #require(DashQL.tools(host: host).first { $0.name == "dashql" })
        let widgets = try await tool.run(["query": "from widgets | where kind = note | select title"])
        #expect(widgets["rows"]?.array?.contains(["title": "Runbook links"]) == true)
        let activity = try await tool.run(["query": "from activity where time > -1h | count by source"])
        #expect(activity["rows"]?.array?.contains { $0["source"] == "pull-requests" } == true)
        _ = try await tool.run(["query": .string("from widget \"\(note.id.uuidString)\"")])
        await #expect(throws: ToolError.self) { try await tool.run(["query": "from widget \"nope\""]) }
        let schema = try await DashQL.tools(host: host)[1].run([:])
        #expect(schema["datasets"]?.array?.contains { $0["name"] == "activity" } == true)
    }

    @Test func widgetQueriesFilterTypedRows() async throws {
        struct Pod { let name: String; let restarts: Int; let namespace: String }
        let items = [Pod(name: "a", restarts: 9, namespace: "eu"), Pod(name: "b", restarts: 0, namespace: "eu"), Pod(name: "c", restarts: 4, namespace: "us")]
        let fields: [QueryDataset.Field] = [.init("name"), .init("restarts", "number"), .init("namespace", aliases: ["ns"])]
        let row: (Pod) -> JSONValue = { ["name": .string($0.name), "restarts": .number(Double($0.restarts)), "namespace": .string($0.namespace)] }

        let query = try #require(try WidgetQuery("restarts>0 | sort -restarts", fields: fields))
        #expect(await query.apply(to: items, row: row).map(\.name) == ["a", "c"])
        let structured = try #require(try WidgetQuery("where ns = eu and restarts < 5", fields: fields))
        #expect(await structured.apply(to: items, row: row).map(\.name) == ["b"])
        let piped = try #require(try WidgetQuery("| take 1", fields: fields))
        #expect(await piped.apply(to: items, row: row).map(\.name) == ["a"])
        #expect(try WidgetQuery("  ", fields: fields) == nil)
        let bare = try #require(try WidgetQuery("ns = us or restarts = 0", fields: fields))
        #expect(await bare.apply(to: items, row: row).map(\.name) == ["b", "c"])
        #expect(throws: QueryError.self) { try WidgetQuery("restarts >", fields: fields) }
    }
}
