import Charts
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// Settings › Usage: what Dash's Claude requests consumed, from the calls kept in the store.
/// Costs are the engine's estimates at API prices; on a subscription they count toward the
/// plan's limits instead of a bill.
struct UsageView: View {
    @Environment(AppSettings.self) private var settings
    @Query(sort: \ClaudeCall.date, order: .reverse) private var allCalls: [ClaudeCall]
    @State private var days = 7

    private var calls: [ClaudeCall] {
        let start = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(-Double(days - 1) * 86_400))
        return allCalls.filter { $0.date >= start }
    }

    var body: some View {
        let calls = calls
        let totals = ClaudeUsage.Totals(calls)
        Form {
            PlanLimitsSection(executable: settings.claudeExecutable)
            Section {
                Picker("Period", selection: $days) {
                    Text("Today").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 24) {
                    MetricView(totals.costUSD.formatted(.currency(code: "USD")), label: "Estimated cost")
                    MetricView(totals.calls.formatted(), label: "Requests")
                    MetricView(tokens(totals.inputTokens + totals.outputTokens), label: "Tokens")
                    MetricView(totals.calls == 0 ? "—" : (totals.costUSD / Double(totals.calls)).formatted(.currency(code: "USD")),
                               label: "Per request")
                    MetricView(totals.errors.formatted(), label: "Failed", tone: totals.errors > 0 ? .warning : .neutral)
                }
            } header: {
                Text("Dash's requests")
            } footer: {
                Text("Every Dashii request Dash makes (chat, PR reviews, plugin tasks), kept in Dash's database. Costs are the engine's estimates at API prices; on a Dashii subscription they count toward your plan's limits rather than a bill. Agents run their own Dashii sessions and aren't included.")
            }

            if calls.isEmpty {
                Section { Text("No Dashii requests in this period.").foregroundStyle(.secondary) }
            } else {
                Section("Cost per day, by model") {
                    Chart(daily(calls), id: \.id) { point in
                        BarMark(x: .value("Day", point.day, unit: .day), y: .value("Cost", point.cost))
                            .foregroundStyle(by: .value("Model", point.model))
                    }
                    .chartYAxis { AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let cost = value.as(Double.self) { Text(cost.formatted(.currency(code: "USD"))) } }
                    } }
                    .frame(height: 200)
                }
                Section("Tokens per day") {
                    Chart(dailyTokens(calls), id: \.id) { point in
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("Tokens", point.tokens))
                            .foregroundStyle(by: .value("Kind", point.kind))
                            .interpolationMethod(.monotone)
                    }
                    .frame(height: 160)
                }
                breakdown("By source", groups: Dictionary(grouping: calls, by: \.sourceLabel))
                breakdown("By model", groups: Dictionary(grouping: calls) { DashiiModel(rawValue: $0.model)?.displayName ?? $0.model })
                Section("Recent requests") {
                    ForEach(calls.prefix(25)) { call in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(call.sourceLabel).font(.callout)
                                Text("\(DashiiModel(rawValue: call.model)?.displayName ?? call.model)\(call.effort.map { " · \($0)" } ?? "") · \(call.turns) turns · \(Duration.milliseconds(call.durationMS).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if call.isError { Badge("failed", tone: .danger) }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(call.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(4)))).font(.callout.monospacedDigit())
                                Text("\(tokens(call.totalInputTokens)) in · \(tokens(call.outputTokens)) out").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            RelativeTime(call.date).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func breakdown(_ title: String, groups: [String: [ClaudeCall]]) -> some View {
        let rows = groups.map { (name: $0.key, totals: ClaudeUsage.Totals($0.value)) }.sorted { $0.totals.costUSD > $1.totals.costUSD }
        let total = max(rows.reduce(0) { $0 + $1.totals.costUSD }, 0.000_001)
        return Section(title) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(""); Text("Requests"); Text("Tokens in / out"); Text("Cost"); Text("Share")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(rows, id: \.name) { row in
                    GridRow {
                        Text(row.name)
                        Text(row.totals.calls.formatted())
                        Text("\(tokens(row.totals.inputTokens)) / \(tokens(row.totals.outputTokens))")
                        Text(row.totals.costUSD.formatted(.currency(code: "USD")))
                        ProgressView(value: row.totals.costUSD / total).frame(width: 80)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func tokens(_ count: Int) -> String { count.formatted(.number.notation(.compactName)) }

    private struct DailyCost: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(model)" }
        let day: Date
        let model: String
        let cost: Double
    }

    private struct DailyTokens: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
        let day: Date
        let kind: String
        let tokens: Int
    }

    private func daily(_ calls: [ClaudeCall]) -> [DailyCost] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: calls) { DayModel(day: calendar.startOfDay(for: $0.date), model: DashiiModel(rawValue: $0.model)?.displayName ?? $0.model) }
        return grouped.map { DailyCost(day: $0.key.day, model: $0.key.model, cost: $0.value.reduce(0) { $0 + $1.costUSD }) }
            .sorted { $0.day < $1.day }
    }

    private func dailyTokens(_ calls: [ClaudeCall]) -> [DailyTokens] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: calls) { calendar.startOfDay(for: $0.date) }
        return byDay.flatMap { day, calls in
            [DailyTokens(day: day, kind: "Input", tokens: calls.reduce(0) { $0 + $1.totalInputTokens }),
             DailyTokens(day: day, kind: "Output", tokens: calls.reduce(0) { $0 + $1.outputTokens })]
        }
        .sorted { $0.day < $1.day }
    }

    private struct DayModel: Hashable {
        let day: Date
        let model: String
    }
}
