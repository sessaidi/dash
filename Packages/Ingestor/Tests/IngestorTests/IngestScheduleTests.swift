import DashKit
import DashKitTesting
import Foundation
import Ingestor
import Testing

@MainActor
struct IngestScheduleTests {
    func setUp() throws -> (Shelf, TestHost, TestClock, UserDefaults) {
        let shelf = Shelf(), clock = TestClock()
        let host = try TestHost([shelf])
        shelf.ingestor = makeIngestor(host.synced, clock: clock)
        let defaults = UserDefaults(suiteName: "IngestScheduleTests." + UUID().uuidString)!
        return (shelf, host, clock, defaults)
    }

    func schedule(_ host: TestHost, _ clock: TestClock, _ defaults: UserDefaults, numbers: [Int] = [7, 8]) -> IngestSchedule {
        let schedule = IngestSchedule(prefix: "shelf", defaults: defaults)
        schedule.clock = { clock.now }
        schedule.items = [
            IngestSyncItem(id: "pulls", title: "Pull requests", fetcher: "shelf.pull", defaultMinutes: 5) { numbers.map { ["number": .number(Double($0))] } },
            IngestSyncItem(id: "old", title: "Old pull requests", fetcher: "shelf.pull", defaultMinutes: 60, defaultOn: false) { [["number": 1]] },
        ]
        return schedule
    }

    @Test func dueItemsAreFetchedOncePerInterval() async throws {
        let (shelf, host, clock, defaults) = try setUp()
        let schedule = schedule(host, clock, defaults)
        schedule.start(host: host)
        schedule.stop()
        #expect(schedule.due.map(\.id) == ["pulls"])

        await schedule.runDue()
        #expect(shelf.loads == 2)
        let status = try #require(schedule.status["pulls"])
        #expect(status.lastRun == clock.now && status.fetched == 2 && status.error == nil && !status.isRunning)
        #expect(schedule.nextRun(schedule.items[0]) == clock.now.addingTimeInterval(300) && schedule.nextRun(schedule.items[1]) == nil)
        let stored = try await host.extensions[0].tools[0].run(["number": 8])
        #expect(stored["title"]?.string == "Fix the invoice total")

        clock.advance(299)
        await schedule.runDue()
        #expect(shelf.loads == 2)
        clock.advance(1)
        await schedule.runDue()
        #expect(shelf.loads == 4)

        schedule.set(schedule.items[0], minutes: 15)
        clock.advance(600)
        #expect(schedule.due.isEmpty)
        schedule.set(schedule.items[1], on: true)
        #expect(schedule.due.map(\.id) == ["old"])
    }

    @Test func choicesAndLastRunsSurviveARestart() async throws {
        let (shelf, host, clock, defaults) = try setUp()
        let first = schedule(host, clock, defaults)
        first.start(host: host)
        first.stop()
        first.set(first.items[0], minutes: 30)
        first.set(first.items[1], on: true)
        await first.runDue()
        #expect(shelf.loads == 3)

        let second = schedule(host, clock, defaults)
        #expect(second.minutes(second.items[0]) == 30 && second.isOn(second.items[1]) && second.isOn)
        #expect(second.lastRun(second.items[0]) == clock.now)
        #expect(second.due.isEmpty)

        second.isOn = false
        clock.advance(7200)
        #expect(second.due.isEmpty && second.nextRun(second.items[0]) == nil)
        #expect(!schedule(host, clock, defaults).isOn)
    }

    @Test func anItemWithNothingToFetchStaysDue() async throws {
        let (shelf, host, clock, defaults) = try setUp()
        let schedule = schedule(host, clock, defaults, numbers: [])
        schedule.start(host: host)
        schedule.stop()
        await schedule.runDue()
        #expect(shelf.loads == 0 && schedule.lastRun(schedule.items[0]) == nil && schedule.due.map(\.id) == ["pulls"])
        // With the real clock too: never run is due now.
        schedule.clock = { .now }
        #expect(schedule.due.map(\.id) == ["pulls"])
    }

    @Test func aBlockedScheduleFetchesNothingAndSaysWhy() async throws {
        let (shelf, host, clock, defaults) = try setUp()
        let schedule = schedule(host, clock, defaults)
        let token = Box("Add a token first.")
        schedule.blocked = { token.value }
        schedule.start(host: host)
        schedule.stop()
        await schedule.runNow()
        #expect(shelf.loads == 0 && schedule.status["pulls"]?.error == "Add a token first." && schedule.due.map(\.id) == ["pulls"])

        token.value = nil
        await schedule.runNow("old")
        #expect(shelf.loads == 1 && schedule.status["old"]?.fetched == 1)

        shelf.ingestor = nil
        await schedule.runNow("pulls")
        #expect(schedule.status["pulls"]?.fetched == 0 && schedule.status["pulls"]?.error?.contains("isn't started") == true)
        #expect(schedule.status["pulls"]?.lastRun == clock.now && !schedule.isRunning)
    }
}

@MainActor
final class Box {
    var value: String?
    init(_ value: String?) { self.value = value }
}
