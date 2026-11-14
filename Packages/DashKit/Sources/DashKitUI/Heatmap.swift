import SwiftUI

/// A GitHub-style calendar heatmap: one column per week, one row per weekday, a square per day
/// shaded by its value (four levels, relative to the period's busiest days), a dot for empty
/// days. Month names above, Mon/Wed/Fri on the side, a legend below. Hover a day for its value.
///
/// ```swift
/// ActivityHeatmap(values: tokensPerDay, from: start, to: end) { "\($0.formatted(.number.notation(.compactName))) tokens" }
/// ```
public struct ActivityHeatmap: View {
    /// Totals keyed by the start of each day (`Calendar.current.startOfDay(for:)`).
    let values: [Date: Double]
    let from: Date
    let to: Date
    let tint: Color
    let format: (Double) -> String

    public init(values: [Date: Double], from: Date, to: Date, tint: Color = .green, format: @escaping (Double) -> String = { "\(Int($0))" }) {
        self.values = values
        self.from = from
        self.to = to
        self.tint = tint
        self.format = format
    }

    private let calendar = Calendar.current

    /// Weeks (columns) of seven days (Sunday first), padded to whole weeks.
    private var weeks: [[Date]] {
        let start = calendar.dateInterval(of: .weekOfYear, for: from)?.start ?? calendar.startOfDay(for: from)
        var weeks: [[Date]] = []
        var day = start
        while day <= to {
            var week: [Date] = []
            for _ in 0..<7 {
                week.append(day)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
            weeks.append(week)
        }
        return weeks
    }

    /// Thresholds for the four shades: quartiles of the non-empty days in the period.
    private var thresholds: [Double] {
        let sorted = values.filter { $0.key >= from && $0.key <= to && $0.value > 0 }.map(\.value).sorted()
        guard !sorted.isEmpty else { return [1, 2, 3] }
        return [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    public nonisolated static func level(_ value: Double, thresholds: [Double]) -> Int {
        guard value > 0 else { return 0 }
        return 1 + thresholds.filter { value > $0 }.count
    }

    public var body: some View {
        let allWeeks = weeks
        let thresholds = thresholds
        GeometryReader { geometry in
            let labelWidth: CGFloat = 30
            let gap: CGFloat = 3
            // Squares fill the space: as wide as the weeks allow, as tall as 7 rows allow (labels and
            // legend take about 40 points). Too narrow for every week at a readable size: the most recent ones.
            let byHeight = (geometry.size.height - 40 - gap * 6) / 7
            let fitting = max(1, Int((geometry.size.width - labelWidth) / (Self.minimumCell + gap)))
            let weeks = Array(allWeeks.suffix(fitting))
            let byWidth = (geometry.size.width - labelWidth - gap * CGFloat(weeks.count)) / CGFloat(max(weeks.count, 1))
            let cell = max(Self.minimumCell, min(22, byWidth, byHeight))
            VStack(alignment: .leading, spacing: 6) {
                // Month names over the week in which each month starts.
                HStack(spacing: gap) {
                    Color.clear.frame(width: labelWidth, height: 1)
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                        let first = week.first { calendar.component(.day, from: $0) == 1 && $0 >= from && $0 <= to }
                        let lead = index == 0 ? week.first { $0 >= from && $0 <= to } : nil
                        // The first column names its month unless one starts within the next two weeks.
                        let startsSoon = index == 0 && weeks.prefix(3).dropFirst().contains { $0.contains { calendar.component(.day, from: $0) == 1 } }
                        Text((first ?? (startsSoon ? nil : lead)).map { $0.formatted(.dateTime.month(.abbreviated)) } ?? "")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(row == 1 ? "Mon" : row == 3 ? "Wed" : row == 5 ? "Fri" : "")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: cell, alignment: .leading)
                        }
                    }
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(week, id: \.self) { day in
                                square(day, cell: cell, thresholds: thresholds)
                            }
                        }
                    }
                }
                HStack(spacing: gap) {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    ForEach(0..<5, id: \.self) { level in shade(level, cell: min(cell, 12)) }
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, labelWidth)
            }
        }
        .frame(minHeight: 7 * Self.minimumCell + 58)
    }

    /// Smallest square drawn; below it older weeks are left out instead.
    static let minimumCell: CGFloat = 9

    @ViewBuilder
    private func square(_ day: Date, cell: CGFloat, thresholds: [Double]) -> some View {
        if day < calendar.startOfDay(for: from) || day > to {
            Color.clear.frame(width: cell, height: cell)
        } else {
            let value = values[day] ?? 0
            shade(Self.level(value, thresholds: thresholds), cell: cell)
                .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(value > 0 ? format(value) : "nothing")")
        }
    }

    @ViewBuilder
    private func shade(_ level: Int, cell: CGFloat) -> some View {
        if level == 0 {
            RoundedRectangle(cornerRadius: cell * 0.18).fill(.quaternary.opacity(0.6))
                .frame(width: cell, height: cell)
        } else {
            RoundedRectangle(cornerRadius: cell * 0.18)
                .fill(tint.opacity([0.3, 0.5, 0.72, 1][min(level, 4) - 1]))
                .frame(width: cell, height: cell)
        }
    }
}
