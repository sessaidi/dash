import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The dot in the chat header: Dashii's health at a glance, the details on click.
struct HealthBadge: View {
    @Environment(AppSettings.self) private var settings
    @State private var health = DashiiHealth.shared
    @State private var showing = false

    var body: some View {
        let status = HealthPanel.status(health)
        Button { showing.toggle() } label: {
            Circle().fill(HealthPanel.color(status.level)).frame(width: 8, height: 8)
                .padding(4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(status.title). \(status.detail)")
        .accessibilityLabel("Dashii health: \(status.title)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            HealthPanel().padding(14).frame(width: 380)
        }
        .task { health.refreshCrashes() }
    }
}

/// Dashii's status, the engine and login, the latest runs and recent crashes, with Test Dashii.
struct HealthPanel: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var health = DashiiHealth.shared
    var showsRuns = 5

    static func status(_ health: DashiiHealth) -> DashiiHealth.Status {
        let usage = ClaudeUsage.shared
        return health.status(engine: usage.version, loggedIn: usage.auth?.loggedIn, engineError: usage.error)
    }

    static func color(_ level: DashiiHealth.Level) -> Color {
        switch level {
        case .healthy: .green
        case .degraded: .orange
        case .down: .red
        case .unknown: .secondary
        }
    }

    var body: some View {
        let status = Self.status(health)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Self.color(status.level)).frame(width: 10, height: 10).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.headline)
                    Text(status.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Engine").foregroundStyle(.secondary)
                    Text(ClaudeUsage.shared.version ?? "unknown")
                }
                GridRow {
                    Text("Account").foregroundStyle(.secondary)
                    Text(ClaudeUsage.shared.auth.map { $0.loggedIn ? ($0.email ?? "Logged in") : "Not logged in" } ?? "unknown")
                }
            }
            .font(.caption)
            if !health.runs.isEmpty {
                Text("Latest runs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(health.runs.prefix(showsRuns)) { RunRow(run: $0) }
            }
            if let crash = health.crashes.first {
                Label("Dash crashed \(crash.date.formatted(.relative(presentation: .named))): \(crash.reason.isEmpty ? crash.exception : crash.reason)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            HStack {
                Button("Test Dashii", systemImage: "stethoscope") { Task { await health.test(settings: settings) } }
                    .disabled(health.isTesting)
                    .help("One tiny run on the fast model: Dash's tools must connect and be called (uses a little Dashii usage)")
                if health.isTesting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") {
                    health.refreshCrashes()
                    let executable = settings.claudeExecutable
                    Task { await ClaudeUsage.shared.refresh(executable: executable) }
                }
                Button("Details") { openWindow(id: "debug") }
                    .help("The Debug window's Health pane: every run and crash")
            }
            .controlSize(.small)
        }
    }
}

struct RunRow: View {
    let run: DashiiHealth.Run

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: run.ok && run.toolsConnected != false ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(run.ok && run.toolsConnected != false ? Color.green : Color.red)
            Text(run.source).font(.caption.monospaced())
            if run.toolsConnected == false { Badge("tools", tone: .danger) }
            Text(run.error ?? String(format: "%.1f s", run.seconds)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(run.at, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
        }
        .help(run.error ?? "")
    }
}

/// The Debug window's Health pane: every recorded run and Dash's crash reports in full.
struct HealthPane: View {
    @State private var health = DashiiHealth.shared
    @State private var selected: CrashReport.ID?

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HealthPanel(showsRuns: 0)
                    Divider()
                    Text("Runs (\(health.runs.count))").font(.headline)
                    ForEach(health.runs) { RunRow(run: $0) }
                }
                .padding()
            }
            .frame(minWidth: 380)
            VStack(alignment: .leading, spacing: 8) {
                Text("Crashes (last week)").font(.headline)
                if health.crashes.isEmpty {
                    Text("No crash in the last week.").foregroundStyle(.secondary)
                } else {
                    List(health.crashes, selection: $selected) { crash in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(crash.date.formatted(date: .abbreviated, time: .shortened) + " · Dash " + crash.version).font(.callout.weight(.medium))
                            Text(crash.reason.isEmpty ? crash.exception : crash.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(crash.id)
                    }
                    .frame(minHeight: 120, maxHeight: 200)
                    if let crash = health.crashes.first(where: { $0.id == selected }) ?? health.crashes.first {
                        CrashDetail(crash: crash)
                    }
                }
            }
            .padding()
            .frame(minWidth: 380, maxHeight: .infinity, alignment: .top)
        }
        .task { health.refreshCrashes() }
    }
}

/// One crash, readable: when and which version, what happened in plain words, where in Dash's
/// code (file and line), the full trace folded away, and Copy / Show in Finder.
struct CrashDetail: View {
    let crash: CrashReport
    @State private var showsTrace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Badge("Dash \(crash.version)", tone: .info)
                Text(crash.date.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                Text("· \(crash.date.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Badge(crash.exception, tone: .danger)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What happened").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(crash.explanation).fixedSize(horizontal: false, vertical: true)
            }
            let places = crash.places()
            if !places.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where in Dash").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(places.enumerated()), id: \.offset) { index, frame in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: index == 0 ? "exclamationmark.circle.fill" : "arrow.turn.left.up")
                                .foregroundStyle(index == 0 ? Color.red : Color.secondary)
                                .frame(width: 14)
                            Text(frame.name).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 6)
                            if let place = frame.place {
                                Text(place).font(.caption.monospaced())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        .help(frame.symbol)
                    }
                }
                .padding(10)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
            }
            DisclosureGroup("Full trace (\(crash.details.count) frames)", isExpanded: $showsTrace) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(crash.details.enumerated()), id: \.offset) { _, frame in
                            Text("\(frame.image)  \(frame.symbol)\(frame.place.map { "  (\($0))" } ?? "")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(frame.own ? .primary : .secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .font(.caption)
            HStack {
                Button("Copy Report", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(crash.summary, forType: .string)
                }
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([crash.file]) }
            }
            .controlSize(.small)
        }
    }
}

/// Shown once after Dash crashed: each crash readable, with ways to report or understand it.
struct CrashNoticeSheet: View {
    let crashes: [CrashReport]
    let ask: (String) -> Void
    let done: () -> Void
    @State private var index = 0

    var body: some View {
        let crash = crashes[min(index, crashes.count - 1)]
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(crashes.count == 1 ? "Dash quit unexpectedly" : "Dash quit unexpectedly \(crashes.count) times")
                        .font(.title3.weight(.semibold))
                    Text("Here's what macOS recorded. Nothing was sent anywhere.").foregroundStyle(.secondary)
                }
                Spacer()
                if crashes.count > 1 {
                    HStack(spacing: 4) {
                        Button { index = max(index - 1, 0) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                        Text("\(index + 1) of \(crashes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { index = min(index + 1, crashes.count - 1) } label: { Image(systemName: "chevron.right") }.disabled(index == crashes.count - 1)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Divider()
            CrashDetail(crash: crash)
            Divider()
            HStack {
                Button("Ask Dashii to Explain", systemImage: "sparkles") {
                    ask("Dash crashed. Explain in plain words what likely happened and what to check, from this crash report:\n\n\(crash.summary)")
                    done()
                }
                Spacer()
                Button("OK") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640)
    }
}
