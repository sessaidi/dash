import ClaudeCodeKit
import DashKit
import DashKitUI
import SwiftUI

/// The Dashii Usage widget's layout per size family, shared by the live view and the gallery preview.
///
/// - narrow: the plan meter's percentage as the headline (or what Dash spent today), two key numbers.
/// - medium: the plan meter, the account, three metrics and the top `/usage` tip.
/// - wide: meters and account on the left, a grid of the numbers on the right.
/// - large: every meter, four metrics, and a details panel (average cost per call, budget left, tip).
struct ClaudeUsageSummary: View {
    let account: String?
    let plan: String?
    let requests: Int?
    let sessions: Int?
    let topTip: (Int, String)?
    let spentToday: Double
    let callsToday: Int
    var meters: [ClaudePlanLimits.Meter] = []
    @Environment(\.widgetLayout) private var layout

    private var meter: ClaudePlanLimits.Meter? { meters.first }

    var body: some View {
        switch layout.family {
        case .narrow: narrow
        case .wide: wide
        case .large: large
        default: medium
        }
    }

    // MARK: Families

    private var narrow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meter, let percent = meter.percentUsed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(percent)%").font(.title.weight(.semibold)).monospacedDigit().foregroundStyle(Self.tone(percent).color)
                        Text(meter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ProgressView(value: Double(percent), total: 100).tint(Self.tone(percent).color)
                    if let resets = meter.resets { Text("Resets \(resets)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                HStack(spacing: 8) {
                    tile(requests.map { $0.formatted() } ?? "—", "requests 24h")
                    tile(spentToday.formatted(.currency(code: "USD")), "Dash today")
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spentToday.formatted(.currency(code: "USD"))).font(.title.weight(.semibold)).monospacedDigit()
                    Text("Dash today · \(callsToday) calls").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    tile(requests.map { $0.formatted() } ?? "—", "requests 24h")
                    tile(sessions.map { $0.formatted() } ?? "—", "sessions")
                }
            }
            Spacer(minLength: 0)
            Text([plan, account ?? "Not logged in"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let meter { PlanMeterRow(meter: meter) }
            accountLine
            HStack(spacing: 16) {
                MetricView(requests.map { $0.formatted() } ?? "—", label: "Requests 24h")
                MetricView(sessions.map { $0.formatted() } ?? "—", label: "Sessions")
                MetricView(spentToday.formatted(.currency(code: "USD")), label: "Dash today (\(callsToday))")
            }
            if meter == nil { tipView }
            Spacer(minLength: 0)
        }
    }

    private var wide: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                accountLine
                ForEach(meters.prefix(2), id: \.title) { PlanMeterRow(meter: $0) }
                if meters.isEmpty { tipView }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tile(requests.map { $0.formatted() } ?? "—", "requests 24h", prominent: true)
                    tile(sessions.map { $0.formatted() } ?? "—", "sessions", prominent: true)
                }
                GridRow {
                    tile(spentToday.formatted(.currency(code: "USD")), "Dash today", prominent: true)
                    tile("\(callsToday)", "Dash calls today", prominent: true)
                }
            }
            .frame(width: 280)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountLine
            ForEach(meters, id: \.title) { PlanMeterRow(meter: $0) }
            HStack(spacing: 16) {
                MetricView(requests.map { $0.formatted() } ?? "—", label: "Requests 24h")
                MetricView(sessions.map { $0.formatted() } ?? "—", label: "Sessions")
                MetricView(spentToday.formatted(.currency(code: "USD")), label: "Dash today")
                MetricView("\(callsToday)", label: "Dash calls today")
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                details.frame(maxWidth: .infinity, alignment: .leading)
                if topTip != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("From /usage").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        tipView
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Pieces

    private var accountLine: some View {
        HStack(spacing: 6) {
            if let plan { Badge(plan, tone: .info, systemImage: "sparkles") }
            Text(account ?? "Not logged in").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private var tipView: some View {
        if let (percent, text) = topTip {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(percent), total: 100)
                Text("\(percent)% · \(text)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// Average cost per Dash call, budget left and the reset date.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Average per Dash call").foregroundStyle(.secondary)
                    Text(callsToday == 0 ? "—" : (spentToday / Double(callsToday)).formatted(.currency(code: "USD").precision(.fractionLength(3))))
                }
                if let meter, let spent = meter.spent, let limit = meter.limit {
                    GridRow {
                        Text("Budget left").foregroundStyle(.secondary)
                        Text((limit - spent).formatted(.currency(code: "USD")))
                    }
                }
                if let resets = meter?.resets {
                    GridRow {
                        Text("Resets").foregroundStyle(.secondary)
                        Text(resets)
                    }
                }
            }
            .font(.callout).monospacedDigit()
        }
    }

    private func tile(_ value: String, _ label: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(prominent ? .title3.bold() : .callout.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, prominent ? 8 : 5)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 7))
    }

    static func tone(_ percent: Int) -> Tone {
        switch percent {
        case 90...: .danger
        case 70..<90: .warning
        default: .success
        }
    }
}
