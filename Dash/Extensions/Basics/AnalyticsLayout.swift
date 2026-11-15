import Charts
import DashKit
import DashKitUI
import SwiftUI

/// The numbers under an activity heatmap: total, peak day, active days, streak, and totals per week.
struct ActivitySummary {
    let total: Double
    let peak: (day: Date, value: Double)?
    let activeDays: Int
    let streak: Int
    /// Sum per week (keyed by the week's first day), oldest first, for the period `from`…`to`.
    let weeks: [(start: Date, value: Double)]

    init(values: [Date: Double], from: Date, to: Date, calendar: Calendar = .current) {
        total = values.values.reduce(0, +)
        peak = values.max { $0.value < $1.value }.flatMap { $0.value > 0 ? ($0.key, $0.value) : nil }
        activeDays = values.values.filter { $0 > 0 }.count
        // Consecutive days with activity ending at the period's last day (or the day before).
        var day = calendar.startOfDay(for: to)
        if (values[day] ?? 0) == 0 { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while (values[day] ?? 0) > 0 {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        self.streak = streak
        var byWeek: [Date: Double] = [:]
        var week = calendar.dateInterval(of: .weekOfYear, for: from)?.start ?? calendar.startOfDay(for: from)
        while week <= to {
            byWeek[week] = 0
            week = calendar.date(byAdding: .weekOfYear, value: 1, to: week)!
        }
        for (day, value) in values where day >= calendar.startOfDay(for: from) && day <= to {
            if let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start { byWeek[start, default: 0] += value }
        }
        weeks = byWeek.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The average over days with any activity.
    var perActiveDay: Double { activeDays == 0 ? 0 : total / Double(activeDays) }
}

/// An activity heatmap with its summary, per size family. Shared by Workspace Analytics and
/// Activity Heatmap, live and in the gallery.
///
/// - narrow: the total as a headline, active days and streak, the most recent weeks.
/// - medium: four stat tiles over the heatmap, the sources bar under it.
/// - wide: the heatmap beside a panel of stats and sources.
/// - large: stats, the heatmap, then a per-week chart beside the sources (or averages).
struct AnalyticsLayout: View {
    var heading = "Activity"
    let metric: String
    let values: [Date: Double]
    let from: Date
    let to: Date
    let sources: [(String, Double)]
    let title: String
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?
    var tint: Color = .green
    /// Overrides the metric's formatting (series from extensions).
    var formatter: ((Double) -> String)?
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        let summary = ActivitySummary(values: values, from: from, to: to)
        switch layout.family {
        case .narrow: narrow(summary)
        case .wide: wide(summary)
        case .large: large(summary)
        default: medium(summary)
        }
    }

    // MARK: Families

    private func narrow(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(compact: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(format(summary.total)).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text("\(summary.activeDays) active days · \(summary.streak)-day streak")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            heatmap
            if let top = sources.first {
                Text("Mostly \(top.0) · \(percent(top.1))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func medium(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(compact: false)
            HStack(spacing: 8) { statTiles(summary) }
            heatmap
            if !sources.isEmpty { sourcesBar }
        }
    }

    private func wide(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(compact: false)
            HStack(alignment: .top, spacing: 16) {
                heatmap.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        let tiles = statList(summary)
                        GridRow { stat(tiles[0]); stat(tiles[1]) }
                        GridRow { stat(tiles[2]); stat(tiles[3]) }
                    }
                    if sources.isEmpty { averages(summary) } else { sourcesList }
                    Spacer(minLength: 0)
                }
                .frame(width: 230)
            }
        }
    }

    private func large(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(compact: false)
            HStack(spacing: 8) { statTiles(summary) }
            heatmap.frame(minHeight: 140)
            HStack(alignment: .top, spacing: 16) {
                weeklyChart(summary).frame(maxWidth: .infinity)
                Group {
                    if sources.isEmpty { averages(summary) } else { sourcesList }
                }
                .frame(width: 240, alignment: .topLeading)
            }
            .frame(height: 130)
        }
    }

    // MARK: Pieces

    private func header(compact: Bool) -> some View {
        HStack(spacing: 4) {
            Text(heading).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(1)
            Spacer(minLength: 4)
            Button("Earlier", systemImage: "chevron.left") { onPrevious?() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(onPrevious == nil)
            Text(title).font(compact ? .caption : .callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Button("Later", systemImage: "chevron.right") { onNext?() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(onNext == nil)
        }
    }

    private var heatmap: some View {
        ActivityHeatmap(values: values, from: from, to: to, tint: tint, format: format)
            .frame(maxHeight: .infinity)
    }

    /// Total, peak day, active days, streak.
    private func statList(_ summary: ActivitySummary) -> [(value: String, label: String)] {
        let peak: (String, String) = summary.peak.map { (format($0.value), "peak · \($0.day.formatted(.dateTime.month(.abbreviated).day()))") } ?? ("—", "peak")
        return [(format(summary.total), "total"), peak, ("\(summary.activeDays)", "active days"), ("\(summary.streak)", "day streak")]
    }

    @ViewBuilder
    private func statTiles(_ summary: ActivitySummary) -> some View {
        ForEach(statList(summary), id: \.label) { stat($0) }
    }

    private func stat(_ entry: (value: String, label: String)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.value).font(.callout.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(entry.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 7))
    }

    private var sourceColors: [Color] { [tint, tint.opacity(0.6), tint.opacity(0.35), .secondary.opacity(0.4)] }

    private func sourceColor(_ index: Int) -> Color { sourceColors[min(index, sourceColors.count - 1)] }

    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    /// Where the activity came from: one bar split by share, and a one-line legend.
    private var sourcesBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, entry in
                        sourceColor(index).frame(width: max(2, geometry.size.width * entry.1 - 2))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 4) {
                        Circle().fill(sourceColor(index)).frame(width: 6, height: 6)
                        Text(entry.0).lineLimit(1).truncationMode(.middle)
                        Text(percent(entry.1)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }

    /// Sources one per line, each with its share as a bar.
    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(sources.enumerated()), id: \.offset) { index, entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Circle().fill(sourceColor(index)).frame(width: 6, height: 6)
                        Text(entry.0).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(percent(entry.1)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                    ProgressView(value: min(max(entry.1, 0), 1)).tint(sourceColor(index)).controlSize(.mini)
                }
            }
        }
    }

    /// For series without sources: what a typical day and week look like.
    private func averages(_ summary: ActivitySummary) -> some View {
        let best = summary.weeks.max { $0.value < $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Averages").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Per active day").foregroundStyle(.secondary)
                    Text(format(summary.perActiveDay)).monospacedDigit()
                }
                GridRow {
                    Text("Per week").foregroundStyle(.secondary)
                    Text(format(summary.weeks.isEmpty ? 0 : summary.total / Double(summary.weeks.count))).monospacedDigit()
                }
                if let best, best.value > 0 {
                    GridRow {
                        Text("Best week").foregroundStyle(.secondary)
                        Text("\(format(best.value)) · \(best.start.formatted(.dateTime.month(.abbreviated).day()))").monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    /// Totals per week, so trends show where the heatmap shows days.
    private func weeklyChart(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(summary.weeks, id: \.start) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Total", week.value))
                    .foregroundStyle(tint.gradient)
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(compact(amount)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
    }

    private func compact(_ value: Double) -> String {
        metric == "cost" ? value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
            : value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private func format(_ value: Double) -> String {
        if let formatter { return formatter(value) }
        return switch metric {
        case "cost": value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
        case "requests": "\(Int(value)) requests"
        default: "\(value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))) tokens"
        }
    }
}
