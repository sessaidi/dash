import DashKit
import Foundation
import SwiftUI
import Testing
@testable import Dash

/// An extension with one fetcher that stores a page, and fails on demand.
@MainActor
private final class PagesExtension: DashExtension {
    let id = "pages"
    let name = "Pages"
    let systemImage = "doc"
    var fail = false
    var fetched: [String] = []
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func start(host: any ExtensionContext) {}
    var fetchers: [DataFetcher] {
        [DataFetcher(name: "pages.page", summary: "One page.", properties: ["id": JSONSchema.string("Page id.")], required: ["id"]) { [weak self] input in
            guard let self else { return nil }
            if fail { throw ToolError("Pages is offline.") }
            fetched.append(input["id"]?.string ?? "")
            return ["stored": 1, "unchanged": 0, "keys": ["page/1"], "read_with": "pages_page"]
        }]
    }
}

@MainActor
struct FetchToolsTests {
    @Test func fetchesAreLimitedPerFetcherAndLogged() async throws {
        let pages = PagesExtension()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "fetch-\(UUID())")!)
        settings.fetchesPerMinute = 2
        let host = try ExtensionHost(settings: settings, extensions: ExtensionHost.builtInExtensions() + [pages], inMemory: true)
        let limiter = FetchLimiter()

        let receipt = try await FetchTools.fetch("pages.page", ["id": "1", "token": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"], host: host, caller: "dashii", limiter: limiter)
        #expect(receipt["stored"] == 1)
        let fetched = try #require(host.activity.events.last)
        #expect(fetched.kind == "data.fetched" && fetched.source == "pages" && fetched.title == "Fetched pages.page")
        #expect(fetched.detail?.hasPrefix("dashii · ") == true && fetched.detail?.hasSuffix("→ stored 1, unchanged 0") == true)
        // Inputs are logged sanitized.
        #expect(fetched.detail?.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789") == false)

        _ = try await FetchTools.fetch("pages.page", ["id": "2"], host: host, caller: "agent Watch SRE", limiter: limiter)
        await #expect(throws: ToolError.self) {
            _ = try await FetchTools.fetch("pages.page", ["id": "3"], host: host, caller: "dashii", limiter: limiter)
        }
        #expect(pages.fetched == ["1", "2"])
        #expect(host.activity.events.last?.kind == "data.fetch_limited")

        pages.fail = true
        let other = FetchLimiter()
        await #expect(throws: ToolError("Pages is offline.")) {
            _ = try await FetchTools.fetch("pages.page", ["id": "4"], host: host, caller: "dashii", limiter: other)
        }
        #expect(host.activity.events.last.map { $0.kind == "data.fetch_failed" && $0.detail?.hasSuffix("→ Pages is offline.") == true } == true)
    }

    @Test func theLimitIsASlidingMinutePerFetcher() {
        let limiter = FetchLimiter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(limiter.wait(for: "a", limit: 2, now: start) == nil)
        #expect(limiter.wait(for: "a", limit: 2, now: start.addingTimeInterval(10)) == nil)
        #expect(limiter.wait(for: "a", limit: 2, now: start.addingTimeInterval(20)) == 40)
        #expect(limiter.wait(for: "b", limit: 2, now: start.addingTimeInterval(20)) == nil)
        #expect(limiter.wait(for: "a", limit: 2, now: start.addingTimeInterval(61)) == nil)
    }

    @Test func receiptSummaries() {
        #expect(FetchTools.summary(of: ["stored": 2, "unchanged": 1, "keys": []]) == "stored 2, unchanged 1")
        #expect(FetchTools.summary(of: ["stored": 3]) == "stored 3")
        #expect(FetchTools.summary(of: ["pages": 4]) == #"{"pages":4}"#)
    }
}
