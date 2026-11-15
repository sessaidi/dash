import DashKit
import DashKitUI
import Foundation
import Testing
@testable import Dash

@MainActor
struct NotifierTests {
    private func event(_ importance: ActivityEvent.Importance) -> ActivityEvent {
        ActivityLog().emit("review.completed", source: "pull-requests", title: "t", importance: importance)
    }

    @Test func notifiesOnlyInTheBackgroundForImportantEvents() {
        #expect(Notifier.shouldNotify(event(.critical), enabled: true, chattiness: .important, appActive: false, lastSent: nil))
        #expect(!Notifier.shouldNotify(event(.critical), enabled: true, chattiness: .important, appActive: true, lastSent: nil))
        #expect(!Notifier.shouldNotify(event(.notable), enabled: true, chattiness: .important, appActive: false, lastSent: nil))
        #expect(Notifier.shouldNotify(event(.notable), enabled: true, chattiness: .everything, appActive: false, lastSent: nil))
        #expect(!Notifier.shouldNotify(event(.critical), enabled: false, chattiness: .everything, appActive: false, lastSent: nil))
    }

    @Test func throttlesPerKind() {
        let now = Date()
        #expect(!Notifier.shouldNotify(event(.critical), enabled: true, chattiness: .important, appActive: false, lastSent: now.addingTimeInterval(-30), now: now))
        #expect(Notifier.shouldNotify(event(.critical), enabled: true, chattiness: .important, appActive: false, lastSent: now.addingTimeInterval(-200), now: now))
    }

    @Test func tipsQueueShowsUnreadAndAttention() {
        let mascot = MascotController(cooldown: 30, greeted: true)
        let log = ActivityLog()
        log.emit("a", source: "s", title: "one", importance: .critical)
        log.emit("b", source: "s", title: "two", importance: .critical)
        mascot.observe(log.events, chattiness: .important)
        #expect(mascot.bubble?.text == "one" && mascot.unread == 1 && mascot.attention)
        mascot.clearQueue()
        #expect(mascot.unread == 0)
    }

    @Test func activityObserversSeeEveryEvent() {
        let log = ActivityLog()
        var seen: [String] = []
        log.onEmit { seen.append($0.title) }
        log.emit("k", source: "s", title: "x")
        log.emit("k", source: "s", title: "y")
        #expect(seen == ["x", "y"])
    }
}
