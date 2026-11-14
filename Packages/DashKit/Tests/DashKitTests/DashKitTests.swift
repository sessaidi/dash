import Foundation
import Testing
@testable import DashKit

struct MetadataTests {
    @Test func versionsCompareNumerically() {
        #expect(ExtensionMetadata.compare("1.10.0", "1.9.3") == .orderedDescending)
        #expect(ExtensionMetadata.compare("1.0", "1.0.0") == .orderedSame)
        #expect(ExtensionMetadata(minimumDashKit: "99.0").isCompatible == false)
        #expect(ExtensionMetadata(minimumDashKit: DashKitInfo.version).isCompatible)
    }
}

@MainActor
struct ActivityTests {
    @Test func logKeepsOrderCapacityAndCursor() {
        let log = ActivityLog(capacity: 3)
        for index in 1...5 { log.emit("tick", source: "test", title: "event \(index)") }
        #expect(log.events.map(\.title) == ["event 3", "event 4", "event 5"])
        #expect(log.events(after: 4).map(\.title) == ["event 5"])
        #expect(log.latestID == 5)
    }

    @Test func digestPutsNotableFirstAndCountsTheRest() throws {
        let log = ActivityLog()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<10 { log.emit("widget.moved", source: "dashboard", title: "moved \(index)", at: start.addingTimeInterval(Double(index))) }
        log.emit("review.completed", source: "pull-requests", title: "Claude reviewed acme/api#812", detail: "request changes, high risk",
                 importance: .notable, at: start.addingTimeInterval(20))
        let digest = try #require(ActivityLog.digest(log.events, limit: 4))
        #expect(digest.contains("11 events"))
        #expect(digest.contains("Claude reviewed acme/api#812 — request changes, high risk"))
        #expect(digest.contains("7 older routine events omitted"))
        #expect(ActivityLog.digest([]) == nil)
    }
}

@Test func activitySeriesGroupsByDay() {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    let interval = DateInterval(start: day, duration: 2 * 86_400)
    let dates = [day.addingTimeInterval(3600), day.addingTimeInterval(7200), day.addingTimeInterval(86_400 + 60), day.addingTimeInterval(-60)]
    #expect(ActivitySeries.countPerDay(dates, in: interval, calendar: calendar) == [day: 2, calendar.date(byAdding: .day, value: 1, to: day)!: 1])
    #expect(ActivitySeries.sumPerDay([(day, 1.5), (day, 2)], in: interval) == [day: 3.5])
}

@Test func shellEnvironmentParsesAfterTheMarker() {
    let data = Data("Welcome!\n__DASH_ENV__DOCKER_HOST=unix:///x.sock\0PATH=/a:/b\0MULTI=line1\nline2\0_=/usr/bin/env\0".utf8)
    let parsed = ShellEnvironment.parse(data)
    #expect(parsed["DOCKER_HOST"] == "unix:///x.sock" && parsed["PATH"] == "/a:/b" && parsed["MULTI"] == "line1\nline2")
    #expect(parsed["_"] == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_SHELL_ENV"] != nil))
func shellEnvironmentReadsTheLoginShell() {
    let shell = ShellEnvironment.shell
    print("SHELLENV DOCKER_HOST=\(shell["DOCKER_HOST"] ?? "nil") keys=\(shell.count)")
    #expect(!shell.isEmpty)
}
