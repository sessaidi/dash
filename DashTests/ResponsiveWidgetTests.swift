import AppKit
import DashKit
import DashKitUI
import Foundation
import SwiftUI
import Testing
@testable import Dash

/// The built-in widgets lay out differently per size family; each layout must build and lay out.
@MainActor
struct ResponsiveWidgetTests {
    /// A content size inside each family.
    static let sizes: [WidgetLayout.Family: CGSize] = [
        .narrow: CGSize(width: 260, height: 220),
        .medium: CGSize(width: 480, height: 320),
        .wide: CGSize(width: 760, height: 300),
        .large: CGSize(width: 900, height: 560),
    ]

    /// Lays the view out at `size` with that size's family, so every family's body is evaluated.
    private func render(_ view: some View, at size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.environment(\.widgetLayout, WidgetLayout(size: size)).frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test func sizesCoverEveryFamily() {
        for family in WidgetLayout.Family.allCases {
            #expect(WidgetLayout.family(for: Self.sizes[family]!) == family)
        }
    }

    @Test(arguments: WidgetLayout.Family.allCases)
    func everyBasicsWidgetPreviewBuilds(family: WidgetLayout.Family) throws {
        let size = Self.sizes[family]!
        for type in BasicsExtension().widgets {
            let preview = try #require(type.preview, "\(type.kind) has no preview")
            let host = render(preview(type.defaultConfig), at: size)
            #expect(host.fittingSize.width > 0, "\(type.kind) at \(family)")
        }
    }

    @Test(arguments: WidgetLayout.Family.allCases)
    func everyDataViewBuilds(family: WidgetLayout.Family) {
        for view in ["table", "list", "counts", "number", "bars"] {
            let host = render(DataWidgetPreview(config: .init(dataset: "pods", view: view)), at: Self.sizes[family]!)
            #expect(host.fittingSize.width > 0, "\(view) at \(family)")
        }
    }

    @Test(arguments: WidgetLayout.Family.allCases)
    func dataLayoutsBuildWithASelectedRow(family: WidgetLayout.Family) {
        for view in ["table", "list"] {
            let content = DataWidgetContent(config: .init(dataset: "pods", view: view), rows: DataWidgetPreview.rows(for: view), total: 40,
                                            selected: .constant(1))
            let host = render(content, at: Self.sizes[family]!)
            #expect(host.fittingSize.width > 0)
        }
    }

    @Test(arguments: WidgetLayout.Family.allCases)
    func usageLayoutsBuildWithAndWithoutPlanMeters(family: WidgetLayout.Family) {
        let withMeters = ClaudeUsageSummary(account: "you@example.com", plan: "Max", requests: 12, sessions: 2, topTip: (40, "Run /clear"),
                                            spentToday: 0.5, callsToday: 3,
                                            meters: [.init(title: "Current session", percentUsed: 92, resets: "3pm"), .init(title: "Current week", percentUsed: 30)])
        let without = ClaudeUsageSummary(account: nil, plan: nil, requests: nil, sessions: nil, topTip: nil, spentToday: 0, callsToday: 0)
        #expect(render(withMeters, at: Self.sizes[family]!).fittingSize.width > 0)
        #expect(render(without, at: Self.sizes[family]!).fittingSize.width > 0)
    }

    @Test(arguments: WidgetLayout.Family.allCases)
    func heatmapLayoutBuildsWithoutSources(family: WidgetLayout.Family) {
        let end = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .month, value: -3, to: end)!
        let layout = AnalyticsLayout(heading: "Commits", metric: "", values: [end: 3], from: start, to: end, sources: [], title: "Aug – Nov",
                                     onPrevious: nil, onNext: nil, formatter: { "\(Int($0)) commits" })
        #expect(render(layout, at: Self.sizes[family]!).fittingSize.width > 0)
    }

    @Test func activitySummaryCountsStreakPeakAndWeeks() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func day(_ back: Int) -> Date { calendar.date(byAdding: .day, value: -back, to: today)! }
        let start = day(27)
        let values: [Date: Double] = [day(0): 2, day(1): 5, day(2): 1, day(10): 9, day(20): 0]
        let summary = ActivitySummary(values: values, from: start, to: today)
        #expect(summary.total == 17)
        #expect(summary.activeDays == 4)
        #expect(summary.streak == 3)
        #expect(summary.peak?.value == 9)
        #expect(summary.peak?.day == day(10))
        #expect(summary.weeks.map(\.value).reduce(0, +) == 17)
        #expect(summary.weeks.count >= 4)
        #expect(summary.perActiveDay == 17.0 / 4)
    }

    @Test func activitySummaryOfNothing() {
        let today = Calendar.current.startOfDay(for: .now)
        let summary = ActivitySummary(values: [:], from: today, to: today)
        #expect(summary.peak == nil)
        #expect(summary.streak == 0)
        #expect(summary.perActiveDay == 0)
    }

    @Test func dataPairsAndFields() {
        let rows: [JSONValue] = [["status": "Running", "count": 24], ["status": "Error", "count": 1]]
        let pairs = DataWidgetContent.pairs(rows)
        #expect(pairs.map(\.label) == ["Running", "Error"])
        #expect(pairs.map(\.value) == [24, 1])
        #expect(DataWidgetContent.fields(of: [["zeta": 1, "name": "a", "status": "ok", "nested": ["x": 1]]]) == ["name", "status", "zeta"])
    }

    @Test func noteCounts() {
        #expect(NoteView.counts("one two\nthree") == "3 words · 2 lines")
        #expect(NoteView.counts("solo") == "1 word · 1 line")
    }
}
