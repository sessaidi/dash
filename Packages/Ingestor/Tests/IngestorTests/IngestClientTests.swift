import DashKit
import DashKitTesting
import Foundation
import Ingestor
import Testing

@MainActor
struct IngestClientTests {
    /// A client on its own stub host (tests run in parallel).
    func client(_ host: String, store: (any SyncedStore)? = nil, clock: TestClock = TestClock()) -> IngestClient {
        let connection = IntegrationConnection(baseURL: URL(string: "https://\(host)")!, headers: ["Authorization": "Bearer test"], session: StubHTTP.session)
        var client = IngestClient(connection: connection, service: "Acme", scope: "acme:\(host)", store: store, source: "acme")
        client.clock = { clock.now }
        return client
    }

    @Test func aRepeatedRequestSendsTheETagAndGetsTheStoredCopy() async throws {
        StubHTTP.serve("etag.acme.test") { request in
            request.value(forHTTPHeaderField: "If-None-Match") == #""v1""#
                ? (304, Data(), [:])
                : (200, Data(#"{"title":"Fix the invoice total"}"#.utf8), ["ETag": #""v1""#])
        }
        let store = MemorySyncedStore()
        let client = client("etag.acme.test", store: store)
        let first = try await client.get("/repos/acme/billing-api/pulls/1")
        let second = try await client.get("/repos/acme/billing-api/pulls/1")
        #expect(!first.fromCache && first.json["title"]?.string == "Fix the invoice total")
        #expect(second.fromCache && second.status == 304 && second.json == first.json)
        let requests = StubHTTP.requests("etag.acme.test")
        #expect(requests.count == 2 && requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test")
        #expect(store.records(kind: IngestClient.etagKind, scope: "acme:etag.acme.test").count == 1)
        // Without a store, nothing is conditional.
        _ = try await self.client("etag.acme.test").get("/repos/acme/billing-api/pulls/1")
        #expect(StubHTTP.requests("etag.acme.test").last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func pagesFollowLinkHeadersTokensAndLinks() async throws {
        StubHTTP.serve("pages.acme.test") { request in
            switch request.url?.path() ?? "" {
            case "/list" where request.url?.query() == "page=2": (200, Data("[3]".utf8), [:])
            case "/list": (200, Data("[1,2]".utf8), ["Link": #"<https://pages.acme.test/list?page=2>; rel="next", <https://pages.acme.test/list?page=2>; rel="last""#])
            case "/tokens" where request.url?.query()?.contains("pageToken=a%2Bb") == true: (200, Data(#"{"items":[3]}"#.utf8), [:])
            case "/tokens": (200, Data(#"{"items":[1,2],"nextPageToken":"a+b"}"#.utf8), [:])
            case "/links" where request.url?.query() == "cursor=2": (200, Data(#"{"results":[3],"_links":{}}"#.utf8), [:])
            case "/links": (200, Data(#"{"results":[1,2],"_links":{"next":"/links?cursor=2"}}"#.utf8), [:])
            default: (404, Data(), [:])
            }
        }
        let client = client("pages.acme.test")
        #expect(try await client.pages("/list", paging: .linkHeader) == [1, 2, 3])
        #expect(try await client.pages("/tokens?per=2", paging: .token(field: "nextPageToken", parameter: "pageToken")) { $0["items"]?.array } == [1, 2, 3])
        #expect(try await client.pages("/links", paging: .link(["_links", "next"])) { $0["results"]?.array } == [1, 2, 3])
        #expect(try await client.pages("/list", paging: .linkHeader, maxPages: 1) == [1, 2])
        await #expect(throws: ToolError.self) { try await client.get("https://elsewhere.test/list") }
    }

    @Test func passingFailuresAreTriedAgainWithGrowingWaits() async throws {
        StubHTTP.serve("flaky.acme.test") { request in
            let tries = StubHTTP.requests("flaky.acme.test").filter { $0.url?.path() == request.url?.path() }.count
            switch request.url?.path() ?? "" {
            case "/flaky": return tries < 3 ? (503, Data(#"{"message":"busy"}"#.utf8), [:]) : (200, Data(#"{"ok":true}"#.utf8), [:])
            case "/down": return (502, Data(), [:])
            case "/log": return tries < 2 ? (500, Data(), [:]) : (200, Data("line 1\nerror: boom".utf8), [:])
            default: return (404, Data(#"{"message":"Not Found"}"#.utf8), [:])
            }
        }
        let waits = Waits()
        var client = client("flaky.acme.test")
        client.sleep = { seconds in await waits.add(seconds) }

        #expect(try await client.json("/flaky") == ["ok": true])
        #expect(StubHTTP.requests("flaky.acme.test").count == 3)
        let first = await waits.all
        #expect(first.count == 2 && (0.4...0.6).contains(first[0]) && (0.8...1.2).contains(first[1]))

        await #expect(throws: HTTPError.self) { try await client.json("/down") }
        #expect(StubHTTP.requests("flaky.acme.test").filter { $0.url?.path() == "/down" }.count == 3)
        await #expect(throws: HTTPError.self) { try await client.json("/missing") }
        #expect(StubHTTP.requests("flaky.acme.test").filter { $0.url?.path() == "/missing" }.count == 1)
        #expect(try await client.text("/log") == "line 1\nerror: boom")

        client.retry = .none
        await #expect(throws: HTTPError.self) { try await client.json("/down") }
        #expect(StubHTTP.requests("flaky.acme.test").filter { $0.url?.path() == "/down" }.count == 4)
    }

    @Test func waitsDoubleUpToTheirCeiling() {
        let retry = IngestRetry(attempts: 6, base: 1, maxDelay: 5, jitter: 0.5)
        #expect((1...5).map { retry.delay(after: $0, random: 0) } == [1, 2, 4, 5, 5])
        #expect(retry.delay(after: 2, random: 1) == 3 && retry.delay(after: 2, random: -1) == 1)
        #expect(IngestRetry.isTransient(URLError(.networkConnectionLost)) && !IngestRetry.isTransient(URLError(.badURL)))
        #expect(IngestRetry.isTransient(HTTPError(service: "Acme", status: 504, message: "")) && !IngestRetry.isTransient(HTTPError(service: "Acme", status: 422, message: "")))
        #expect(IngestRetry(attempts: 0).attempts == 1)
    }

    @Test func aUsedUpRateLimitStopsRequestsUntilItResets() async throws {
        let clock = TestClock()
        let reset = "\(Int(clock.now.timeIntervalSince1970) + 600)"
        StubHTTP.serve("limit.acme.test") { _ in (200, Data("{}".utf8), ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset]) }
        let client = client("limit.acme.test", clock: clock)
        _ = try await client.get("/user")
        await #expect(throws: IngestError.rateLimited(service: "Acme", until: clock.now.addingTimeInterval(600))) { try await client.get("/user") }
        #expect(StubHTTP.requests("limit.acme.test").count == 1)
        clock.advance(601)
        _ = try await client.get("/user")
        #expect(StubHTTP.requests("limit.acme.test").count == 2)

        StubHTTP.serve("busy.acme.test", json: #"{"message":"API rate limit exceeded for user"}"#, status: 403)
        let busy = self.client("busy.acme.test", clock: clock)
        await #expect(throws: IngestError.rateLimited(service: "Acme", until: clock.now.addingTimeInterval(60))) { try await busy.get("/user") }
        #expect(IngestRateLimit.pausedUntil(service: "Acme", scope: "acme:busy.acme.test", now: clock.now) != nil)
        await #expect(throws: IngestError.self) { try await busy.get("/user") }
        #expect(StubHTTP.requests("busy.acme.test").count == 1)
        IngestRateLimit.resume(service: "Acme", scope: "acme:busy.acme.test")
    }
}

/// The waits a client asked for.
actor Waits {
    private(set) var all: [TimeInterval] = []
    func add(_ seconds: TimeInterval) { all.append(seconds) }
}
