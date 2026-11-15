import Foundation
import Testing
@testable import DashKit

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

    @Test func sizeClasses() {
        #expect(WidgetSizeClass(CGSize(width: 240, height: 300)) == .compact)
        #expect(WidgetSizeClass(CGSize(width: 400, height: 300)) == .regular)
        #expect(WidgetSizeClass(CGSize(width: 700, height: 400)) == .large)
    }
}
