import Foundation
import Testing
@testable import Dash

/// Dashii's health and Dash's crash reports.
@MainActor
struct HealthTests {
    private func health() -> DashiiHealth { DashiiHealth(defaults: UserDefaults(suiteName: "health-\(UUID())")!) }

    @Test func statusFollowsTheEngineTheLoginAndTheRuns() {
        let health = health()
        #expect(health.status(engine: nil, loggedIn: nil, engineError: "claude not found").level == .down)
        #expect(health.status(engine: "2.1", loggedIn: false, engineError: nil).title == "Not logged in")
        #expect(health.status(engine: "2.1", loggedIn: true, engineError: nil).level == .unknown)
        health.record(source: "chat", toolsConnected: true, ok: true, error: nil, started: .now)
        #expect(health.status(engine: "2.1", loggedIn: true, engineError: nil).level == .healthy)
        health.record(source: "agent.sre.oncall", toolsConnected: false, ok: false, error: "Dash's tools didn't connect.", started: .now)
        #expect(health.status(engine: "2.1", loggedIn: true, engineError: nil).title == "Dashii's tools didn't connect")
        health.record(source: "chat", toolsConnected: true, ok: false, error: "overloaded", started: .now)
        #expect(health.status(engine: "2.1", loggedIn: true, engineError: nil).level == .down)
    }

    @Test func runsAreKeptAcrossLaunchesNewestFirst() {
        let defaults = UserDefaults(suiteName: "health-\(UUID())")!
        let health = DashiiHealth(defaults: defaults)
        for index in 0..<45 { health.record(source: "chat \(index)", toolsConnected: true, ok: true, error: nil, started: .now) }
        let again = DashiiHealth(defaults: defaults)
        #expect(again.runs.count == 40 && again.runs.first?.source == "chat 44")
    }

    @Test func crashReportsAreReadAndShownOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "crashes-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let header = #"{"app_name":"Dash","app_version":"0.2.6","timestamp":"2026-11-15 23:45:27.00 +0100"}"#
        let body = #"{"captureTime":"2026-11-15 23:45:27.3311 +0100","exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},"usedImages":[{"name":"Dash"},{"name":"libswiftCore.dylib"}],"threads":[{"triggered":true,"frames":[{"imageIndex":1,"symbol":"_assertionFailure"},{"imageIndex":0,"symbol":"NoteDocument.init(_:)","sourceFile":"NoteDocument.swift","sourceLine":17}]}]}"#
        try (header + "\n" + body).write(to: folder.appending(path: "Dash-2026-11-15-234527.ips"), atomically: true, encoding: .utf8)
        try "not a report".write(to: folder.appending(path: "Other-1.ips"), atomically: true, encoding: .utf8)

        let crash = try #require(CrashReports.all(in: folder).first)
        #expect(crash.version == "0.2.6" && crash.exception == "EXC_BREAKPOINT (SIGTRAP)" && crash.reason == "Fatal error: Index out of range")
        // Dash's own frames first.
        #expect(crash.frames.first == "Dash: NoteDocument.init(_:) (NoteDocument.swift:17)")
        let defaults = UserDefaults(suiteName: "crashes-\(UUID())")!
        defaults.set(Date(timeIntervalSince1970: 0), forKey: "health.crashesSeen")
        #expect(CrashReports.unseen(in: folder, defaults: defaults).count == 1)
        CrashReports.markSeen([crash], defaults: defaults)
        #expect(CrashReports.unseen(in: folder, defaults: defaults).isEmpty)
    }
}
