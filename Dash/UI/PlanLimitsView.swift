import ClaudeCodeKit
import DashKit
import DashKitUI
import SwiftUI

/// The plan's limit meters from Claude Code's `/usage`: usage credits (spend against a monthly
/// budget) or session and weekly limits, with when they reset.
struct PlanLimitsSection: View {
    let executable: URL?
    private var usage: ClaudeUsage { .shared }

    var body: some View {
        Section {
            if let meters = usage.limits?.meters, !meters.isEmpty {
                ForEach(meters, id: \.title) { meter in PlanMeterRow(meter: meter) }
            } else if usage.isReadingLimits {
                HStack { ProgressView().controlSize(.small); Text("Reading /usage…").foregroundStyle(.secondary) }
            } else if let error = usage.limitsError {
                Text(error).foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                Spacer()
                if usage.isReadingLimits, usage.limits != nil { ProgressView().controlSize(.small) }
                Button("Refresh Limits") { Task { await usage.refreshLimits(executable: executable) } }
                    .disabled(usage.isReadingLimits)
            }
        } header: {
            Text("Plan limits")
        } footer: {
            Text("From Claude Code's /usage, read in its own folder (Library/Application Support/Dash/claude-status). No model call, no cost.")
        }
        .task { if usage.limits == nil { await usage.refreshLimits(executable: executable) } }
    }
}

struct PlanMeterRow: View {
    let meter: ClaudePlanLimits.Meter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.title).font(.headline)
                Spacer()
                if let percent = meter.percentUsed {
                    Text("\(percent)% used").font(.callout.monospacedDigit()).foregroundStyle(tone.color)
                }
            }
            ProgressView(value: Double(meter.percentUsed ?? 0), total: 100)
                .tint(tone.color)
            HStack {
                if let spent = meter.spent, let limit = meter.limit {
                    Text("\(spent.formatted(.currency(code: "USD"))) of \(limit.formatted(.currency(code: "USD"))) spent")
                        .font(.callout.monospacedDigit())
                    Text("· \((limit - spent).formatted(.currency(code: "USD"))) left").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let resets = meter.resets { Text("Resets \(resets)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
    }

    private var tone: Tone {
        switch meter.percentUsed ?? 0 {
        case 90...: .danger
        case 70..<90: .warning
        default: .success
        }
    }
}
