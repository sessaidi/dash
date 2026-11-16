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
        let body = #"{"procPath":"/Applications/Dash.app/Contents/MacOS/Dash","captureTime":"2026-11-15 23:45:27.3311 +0100","exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},"usedImages":[{"name":"Dash"},{"name":"libswiftCore.dylib"}],"threads":[{"triggered":true,"frames":[{"imageIndex":1,"symbol":"_assertionFailure"},{"imageIndex":0,"symbol":"NoteDocument.init(_:)","sourceFile":"NoteDocument.swift","sourceLine":17}]}]}"#
        try (header + "\n" + body).write(to: folder.appending(path: "Dash-2026-11-15-234527.ips"), atomically: true, encoding: .utf8)
        try "not a report".write(to: folder.appending(path: "Other-1.ips"), atomically: true, encoding: .utf8)

        #expect(CrashReports.anonymized("/Users/me/code/build/Debug/Dash.app/Contents/MacOS/Dash", home: "/Users/me") == "/Users/USER/*/Dash.app/Contents/MacOS/Dash")
        #expect(CrashReports.anonymized("/Applications/Dash.app/Contents/MacOS/Dash", home: "/Users/me") == "/Applications/Dash.app/Contents/MacOS/Dash")
        // Only the running app's crashes count: a test run or development build crashes elsewhere.
        #expect(CrashReports.all(in: folder, executable: "/Users/me/build/Debug/Dash.app/Contents/MacOS/Dash").isEmpty)
        let crash = try #require(CrashReports.all(in: folder, executable: "/Applications/Dash.app/Contents/MacOS/Dash").first)
        #expect(crash.version == "0.2.6" && crash.exception == "EXC_BREAKPOINT (SIGTRAP)" && crash.reason == "Fatal error: Index out of range")
        // Dash's own frames first.
        #expect(crash.frames.first == "Dash: NoteDocument.init(_:) (NoteDocument.swift:17)")
        let defaults = UserDefaults(suiteName: "crashes-\(UUID())")!
        defaults.set(Date(timeIntervalSince1970: 0), forKey: "health.crashesSeen")
        let app = "/Applications/Dash.app/Contents/MacOS/Dash"
        #expect(CrashReports.unseen(in: folder, defaults: defaults, executable: app).count == 1)
        CrashReports.markSeen([crash], defaults: defaults)
        #expect(CrashReports.unseen(in: folder, defaults: defaults, executable: app).isEmpty)
    }
}

/// Crash reports read like a person would explain them.
struct CrashReadabilityTests {
    @Test func framesAndExplanationsAreReadable() {
        let frame = CrashReport.Frame(image: "Dash.debug.dylib", symbol: "partial apply for closure #1 in static CopyMenu.plain(_:)", file: "/x/ChatPanel.swift", line: 276, own: true)
        #expect(frame.name == "CopyMenu.plain(_:)" && frame.place == "ChatPanel.swift:276")
        #expect(CrashReport.Frame(image: "Dash", symbol: "x", file: "/<compiler-generated>", line: nil, own: true).place == nil)
        #expect(CrashReport.isOwn(image: "Dash.debug.dylib", symbol: "CopyMenu.plain(_:)"))
        #expect(!CrashReport.isOwn(image: "DashTests", symbol: "ChatMessageTests.plainTextDropsTheMarks()"))
        #expect(!CrashReport.isOwn(image: "Dash", symbol: "$s9DashTests011ChatMessage"))
        let crash = CrashReport(id: "a", file: URL(filePath: "/tmp/a.ips"), date: .now, version: "0.3.1", exception: "EXC_BREAKPOINT (SIGTRAP)",
                                reason: "Fatal error: Index out of range", frames: [])
        #expect(crash.explanation.contains("Index out of range"))
        let trap = CrashReport(id: "b", file: URL(filePath: "/tmp/b.ips"), date: .now, version: "0.3.1", exception: "EXC_BREAKPOINT (SIGTRAP)", reason: "", frames: [])
        #expect(trap.explanation.contains("safety check"))
    }
}

/// Uncaught exceptions are kept and shown like crash reports.
struct ExceptionReportTests {
    @Test func anUncaughtExceptionBecomesAReport() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "exceptions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let exception = NSException(name: .genericException, reason: "The window has been marked as needing another Update Constraints in Window pass", userInfo: nil)
        CrashReports.saveException(exception, to: folder)
        let report = try #require(CrashReports.all(in: folder, executable: nil).first)
        #expect(report.exception == "NSGenericException (uncaught exception)")
        #expect(report.explanation.contains("layout kept changing"))
        #expect(CrashReports.symbol(fromCallStackLine: "3   AppKit                              0x00000001a0ffb778 -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints] + 1716")
                == "AppKit: -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]")
    }
}
