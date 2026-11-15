import Foundation
import Testing
@testable import DashKit
import DashKitUI

/// The snapshot loader behind `ProvidedWidget`: loads, keeps the last good snapshot, goes stale.
@MainActor
struct WidgetProviderTests {
    final class Counter: WidgetDataProvider {
        var refresh: WidgetRefresh { .every(.seconds(60)) }
        var fail = false
        var calls = 0

        func snapshot(for config: String) async throws -> String {
            calls += 1
            if fail { throw ToolError("offline") }
            return "\(config) #\(calls)"
        }
    }

    @Test func keepsTheLastSnapshotWhenAReloadFails() async {
        let provider = Counter()
        let loader = WidgetSnapshotLoader(provider: provider)
        await loader.load("pods")
        #expect(loader.snapshot == "pods #1" && loader.error == nil && !loader.isStale())
        provider.fail = true
        await loader.load("pods")
        #expect(loader.snapshot == "pods #1" && loader.error == "offline" && loader.isStale())
    }

    @Test func staleAfterTwoIntervals() async {
        let loader = WidgetSnapshotLoader(provider: Counter())
        await loader.load("pods")
        #expect(!loader.isStale(now: .now.addingTimeInterval(100)))
        #expect(loader.isStale(now: .now.addingTimeInterval(130)))
    }

    @Test func familiesFollowTheGridPresets() {
        let roomy = CGSize(width: 900, height: 700)
        #expect(WidgetLayout(size: roomy, columns: 3, rows: 4).family == .narrow)
        #expect(WidgetLayout(size: roomy, columns: 4, rows: 6).family == .medium)
        #expect(WidgetLayout(size: roomy, columns: 6, rows: 9).family == .large)
        #expect(WidgetLayout(size: roomy, columns: 8, rows: 9).family == .wide)
        #expect(WidgetLayout(size: roomy, columns: 12, rows: 12).family == .large)
    }

    @Test func aSmallWindowStepsTheFamilyDown() {
        #expect(WidgetLayout(size: CGSize(width: 390, height: 300), columns: 6, rows: 9).family == .medium)
        #expect(WidgetLayout(size: CGSize(width: 390, height: 300), columns: 8, rows: 9).family == .medium)
        #expect(WidgetLayout(size: CGSize(width: 220, height: 200), columns: 4, rows: 6).family == .narrow)
        #expect(WidgetLayout(size: CGSize(width: 500, height: 300), columns: 6, rows: 9).family == .large)
    }

    @Test func familiesBySize() {
        #expect(WidgetLayout(size: CGSize(width: 240, height: 300)).family == .narrow)
        #expect(WidgetLayout(size: CGSize(width: 400, height: 300)).family == .medium)
        #expect(WidgetLayout(size: CGSize(width: 700, height: 200)).family == .wide)
        #expect(WidgetLayout(size: CGSize(width: 700, height: 400)).family == .large)
    }
}
