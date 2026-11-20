import DashKit
import DashKitTesting
import Foundation
import Ingestor
import Testing

/// Resources described as routes and mappers: Ingestor builds the request, pages, picks the
/// list, maps each item, then sanitizes and stores the answer.
@MainActor
struct IngestRouteTests {
    let run = IngestMapper([
        "id": "id", "workflow": "name", "sha": .prefix("head_sha", 7), "started": "run_started_at|created_at",
        "author": "actor.login", "labels": "labels[].name", "merged": .exists("merged_at"), "title": .firstLine("message"),
        "draft": .path("draft", or: false),
    ])

    @Test func pathsAndQueriesComeFromTheInput() throws {
        let route = IngestRoute("/repos/{repo}/commits/{ref}/check-runs",
                                query: ["branch": .input("branch"), "state": .input("state", default: "open"), "per_page": .limit("limit", default: 15, max: 50),
                                        "since": .compute { $0["since"]?.string.map { $0 + "T00:00:00Z" } }, "fixed": "a b"])
        #expect(try route.url(for: ["repo": "acme/billing-api", "ref": "feature/x y", "limit": 80])
            == "/repos/acme/billing-api/commits/feature/x%20y/check-runs?state=open&per_page=50&fixed=a%20b")
        #expect(try route.url(for: ["repo": "acme/billing-api", "ref": "main", "branch": "dev", "since": "2026-11-01", "state": "closed"])
            == "/repos/acme/billing-api/commits/main/check-runs?branch=dev&state=closed&per_page=15&since=2026%2D11%2D01T00%3A00%3A00Z&fixed=a%20b")
        #expect(try IngestRoute("/runs/{id}").url(for: ["id": 42]) == "/runs/42")
        #expect(throws: ToolError("Give ref.")) { try route.url(for: ["repo": "acme/billing-api"]) }
    }

    @Test func mappersKeepTheFieldsAskedFor() {
        let item: JSONValue = ["id": 11, "name": "CI", "head_sha": "abcdef9999", "created_at": "2026-11-17T08:00:00Z", "actor": ["login": "ada"],
                               "labels": [["name": "backend"], ["color": "red"], ["name": "api"]], "merged_at": "2026-11-18T00:00:00Z",
                               "message": "Fix retries\n\nLonger body", "secret": "not kept"]
        #expect(run.map(item) == ["id": 11, "workflow": "CI", "sha": "abcdef9", "started": "2026-11-17T08:00:00Z", "author": "ada",
                                  "labels": ["backend", "api"], "merged": true, "title": "Fix retries", "draft": false])
        #expect(run.map(["id": 12])["merged"] == false && run.map(["id": 12])["author"] == .null && run.map(["id": 12])["sha"] == "")

        let files = IngestMapper(["file": "filename", "patch": IngestField { item, input in input["patches"]?.bool == true ? item["patch"] : nil }])
        #expect(files.map(["filename": "a.go", "patch": "+x"]) == ["file": "a.go"])
        #expect(files.map(["filename": "a.go", "patch": "+x"], input: ["patches": true]) == ["file": "a.go", "patch": "+x"])
        #expect(IngestMapper.pluck("login").map(["login": "acme", "id": 1]) == "acme")
        #expect(run.adding(["workflow": .constant("renamed")]).map(item)["workflow"] == "renamed")

        let compare = IngestMapper(["commits": .list("commits", IngestMapper(["sha": .prefix("sha", 3)]), limit: .last(2))])
        #expect(compare.map(["commits": [["sha": "aaaa"], ["sha": "bbbb"], ["sha": "cccc"]]]) == ["commits": [["sha": "bbb"], ["sha": "ccc"]]])
    }

    func ingestor(_ host: String, store: MemorySyncedStore = MemorySyncedStore()) -> Ingestor {
        var ingestor = makeIngestor(store, clock: TestClock())
        ingestor.client = IngestClient(connection: IntegrationConnection(baseURL: URL(string: "https://\(host)")!, session: StubHTTP.session),
                                       service: "Acme", scope: ingestor.scope)
        return ingestor
    }

    @Test func theIngestorFetchesMapsAndStoresARoute() async throws {
        StubHTTP.serve("routes.acme.test") { request in
            switch (request.url?.path() ?? "", request.url?.query() ?? "") {
            case ("/repos/acme/billing-api/actions/runs", "per_page=2"):
                (200, Data(#"{"total_count":3,"workflow_runs":[{"id":11,"name":"CI","head_sha":"abcdef9999","token":"ghp_abcdefghijklmnopqrstuvwxyz0123456789"},{"id":12,"name":"Lint"}]}"#.utf8),
                 ["Link": #"<https://routes.acme.test/repos/acme/billing-api/actions/runs?per_page=2&page=2>; rel="next""#])
            case ("/repos/acme/billing-api/actions/runs", "per_page=2&page=2"): (200, Data(#"{"workflow_runs":[{"id":13,"name":"Deploy"}]}"#.utf8), [:])
            case ("/user", _): (200, Data(#"{"login":"ada","name":"Ada"}"#.utf8), [:])
            case ("/user/orgs", _): (200, Data(#"[{"login":"acme"},{"login":"globex"}]"#.utf8), [:])
            case ("/user/status", _): (500, Data(), [:])
            default: (404, Data(), [:])
            }
        }
        let store = MemorySyncedStore()
        var ingestor = ingestor("routes.acme.test", store: store)
        ingestor.client?.retry = .none
        let runs = IngestResource(kind: "acme.runs", reader: "acme_runs", summary: "Runs.", properties: ["repo": JSONSchema.string("owner/name")], required: ["repo"],
                                  route: IngestRoute("/repos/{repo}/actions/runs", query: ["per_page": "2"], items: "workflow_runs", paging: .linkHeader,
                                                     map: run.adding(["token": "token"])))
        try await ingestor.fetch(runs, ["repo": "acme/billing-api"])
        let stored = try #require(try ingestor.stored(runs, ["repo": "acme/billing-api"]))
        #expect(stored.data.array?.compactMap { $0["id"]?.int } == [11, 12, 13])
        #expect(stored.data[0]?["sha"] == "abcdef9" && stored.data[0]?["token"]?.string?.contains("ghp_") == false)

        let whoami = IngestResource(kind: "acme.whoami", reader: "acme_whoami", summary: "Who.", parts: [
            "": IngestRoute("/user", map: IngestMapper(["login": "login", "name": "name"])),
            "organizations": IngestRoute("/user/orgs", map: .pluck("login")),
            "status": IngestRoute("/user/status", optional: true, map: IngestMapper(["message": "message", "emoji": .path("emoji", or: "")])),
        ])
        try await ingestor.fetch(whoami, [:])
        #expect(try ingestor.stored(whoami, [:])?.data == ["login": "ada", "name": "Ada", "organizations": ["acme", "globex"], "status": ["message": .null, "emoji": ""]])

        ingestor.client = nil
        ingestor.notConnected = "Connect Acme first."
        await #expect(throws: ToolError("Connect Acme first.")) { try await ingestor.fetch(runs, ["repo": "acme/billing-api"]) }
    }
}
