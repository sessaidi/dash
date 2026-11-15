import AppKit
@_spi(DashHost) import DashKit
@_spi(DashHost) import DashKitUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Everything needed to debug Dash: environment, logs, activity, network, Claude requests,
/// extension states; exportable as one redacted JSON file.
struct DebugWindow: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(ChatSession.self) private var chat
    @State private var section = Section.overview
    @State private var tick = 0

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", logs = "Logs", activity = "Activity", network = "Network", claude = "Dashii", extensions = "Extensions"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: "info.circle"
            case .logs: "text.alignleft"
            case .activity: "bolt.horizontal"
            case .network: "network"
            case .claude: "sparkles"
            case .extensions: "puzzlepiece.extension"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch section {
                case .overview: OverviewPane()
                case .logs: LogsPane(tick: tick)
                case .activity: ActivityPane()
                case .network: NetworkPane(tick: tick)
                case .claude: ClaudePane()
                case .extensions: ExtensionsPane()
                }
            }
            .navigationTitle(section.rawValue)
            .toolbar {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") { tick += 1 }
                }
                ToolbarItem {
                    Button("Export Diagnostics…", systemImage: "square.and.arrow.up") { export() }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        // Logs and network traces aren't observable; refresh them every few seconds.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                tick += 1
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Dash-diagnostics-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Diagnostics.report(host: host, chat: chat).data(pretty: true).write(to: url, options: .atomic)
            DashLog.notice("Exported diagnostics to \(url.lastPathComponent)", category: "debug")
        } catch {
            DashLog.error("Diagnostics export failed: \(error.localizedDescription)", category: "debug")
        }
    }
}

/// The diagnostics report. Contains no secrets: tokens never leave the Keychain, URLs are
/// stripped of query strings, and only which secrets are set (not their values) is included.
@MainActor
enum Diagnostics {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    static func report(host: ExtensionHost, chat: ChatSession) -> JSONValue {
        let iso = Date.ISO8601FormatStyle()
        return [
            "generated": .string(Date().formatted(iso)),
            "app": ["version": .string(appVersion), "dashkit": .string(DashKitInfo.version),
                    "macOS": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                    "model": .string(host.settings.model), "effort": .string(host.settings.effort), "debugMode": .bool(host.settings.debugMode)],
            "paths": ["store": .string((try? ExtensionHost.storeURL().path) ?? "?"), 
                      "plugins": .string(PluginLoader.userFolder.path)],
            "plugins": .array(host.plugins.map { plugin in
                ["id": .string(plugin.id), "version": .string(plugin.version), "bundled": .bool(plugin.bundled),
                 "signature": .string(plugin.signature), "sha256": .string(plugin.sha256), "state": .string(String(describing: plugin.state))]
            }),
            "extensions": .array(host.extensions.map { item in extensionInfo(item, host: host) }),
            "extensionErrors": .array(host.extensionErrors.map { .string($0) }),
            "pages": .array(host.dashboard.pages().map(host.dashboard.describe)),
            "activity": .array(host.activity.events.suffix(300).map { .string($0.line) }),
            "network": .array(HTTPTrace.entries.suffix(300).map {
                .string("\($0.date.formatted(iso)) \($0.service) \($0.method) \($0.url) \($0.status) \($0.bytes)B \($0.milliseconds)ms")
            }),
            "claude": .array(chat.trace.suffix(100).map {
                .string("\($0.date.formatted(iso)) \($0.model) stop=\($0.stopReason) in=\($0.inputTokens) out=\($0.outputTokens) cacheRead=\($0.cacheReadTokens) tools=\($0.toolCalls.joined(separator: ",")) \($0.milliseconds)ms \($0.error ?? "")")
            }),
            "logs": .array(DashLog.entries.suffix(2000).map { .string("\($0.date.formatted(iso)) [\($0.level.rawValue)] \($0.category): \($0.message)") }),
        ]
    }

    static func extensionInfo(_ item: any DashExtension, host: ExtensionHost) -> JSONValue {
        var info: [String: JSONValue] = [
            "id": .string(item.id), "name": .string(item.name), "layer": .string(item.layer.rawValue),
            "version": .string(item.metadata.version), "author": .string(item.author.name), "source": .string(item.sourceLabel),
            "enabled": .bool(host.isEnabled(item)), "requires": .array(item.requires.map { .string($0) }),
            "unmet": .array(host.unmetRequirements(of: item).map { .string($0) }),
            "tools": .array(item.tools.map { .string($0.name) }), "widgets": .array(item.widgets.map { .string($0.kind) }),
            "secretsSet": .array(item.secretKeys.filter { item.secrets?.contains($0.key) ?? false }.map { .string($0.key) }),
            "data": .object(Dictionary(uniqueKeysWithValues: host.dataSummary(for: item).map { ($0.model, .number(Double($0.count))) })),
        ]
        if let integration = item as? any Integration, item.layer == .integration {
            info["state"] = .string(integration.connectionState.title)
            info["connected"] = .bool(integration.isConnected)
            info["exports"] = integration.exports
        }
        return .object(info)
    }
}

private struct OverviewPane: View {
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        @Bindable var settings = host.settings
        Form {
            Section("App") {
                LabeledContent("Version", value: Diagnostics.appVersion)
                LabeledContent("DashKit", value: DashKitInfo.version)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Model", value: "\(host.settings.model) · effort \(host.settings.effort)")
                Toggle("Debug mode (verbose logging)", isOn: $settings.debugMode)
            }
            Section("Storage") {
                path("Database", (try? ExtensionHost.storeURL()) ?? URL(filePath: "/"))
                path("Plugins folder", PluginLoader.userFolder)
                LabeledContent("Pages", value: "\(host.dashboard.pages().count)")
                LabeledContent("Widgets", value: "\(host.dashboard.widgets().count)")
            }
            Section("Counts") {
                LabeledContent("Extensions", value: "\(host.extensions.count) (\(host.extensions.filter { !host.isEnabled($0) }.count) off)")
                LabeledContent("Plugins", value: "\(host.plugins.count)")
                LabeledContent("Activity events", value: "\(host.activity.events.count)")
                LabeledContent("Log entries", value: "\(DashLog.entries.count)")
                LabeledContent("HTTP requests traced", value: "\(HTTPTrace.entries.count)")
            }
            if !host.extensionErrors.isEmpty {
                Section("Problems") { ForEach(host.extensionErrors, id: \.self) { Text($0).foregroundStyle(.red) } }
            }
        }
        .formStyle(.grouped)
    }

    private func path(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

private struct LogsPane: View {
    let tick: Int
    @State private var minimum: DashLog.Level = .info
    @State private var category = "all"
    @State private var search = ""

    var body: some View {
        let all = DashLog.entries
        let categories = ["all"] + Array(Set(all.map(\.category))).sorted()
        let shown = all.reversed().filter {
            $0.level >= minimum && (category == "all" || $0.category == category)
                && (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search))
        }
        VStack(spacing: 0) {
            HStack {
                Picker("Level", selection: $minimum) { ForEach(DashLog.Level.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .fixedSize()
                Picker("Category", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    .fixedSize()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] \($0.category): \($0.message)" }.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { DashLog.clear() }
            }
            .padding(10)
            Table(Array(shown.prefix(2000))) {
                TableColumn("Time") { Text($0.date.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()) }.width(80)
                TableColumn("Level") { entry in Badge(entry.level.rawValue, tone: tone(entry.level)) }.width(64)
                TableColumn("Category") { Text($0.category).font(.caption.monospaced()) }.width(90)
                TableColumn("Message") { Text($0.message).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3) }
            }
            .id(tick)
            Text("Also in Console.app: subsystem \(DashLog.subsystem). Turn on Debug mode in Overview for per-request logs.")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
    }

    private func tone(_ level: DashLog.Level) -> Tone {
        switch level {
        case .debug: .neutral
        case .info: .info
        case .notice: .accent
        case .error: .warning
        case .fault: .danger
        @unknown default: .neutral
        }
    }
}

private struct ActivityPane: View {
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        Table(host.activity.events.reversed()) {
            TableColumn("Time") { Text($0.date.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()) }.width(80)
            TableColumn("Importance") { event in
                Badge(event.importance.rawValue, tone: event.importance == .critical ? .danger : event.importance == .notable ? .warning : .neutral)
            }.width(80)
            TableColumn("Source") { Text($0.source).font(.caption.monospaced()) }.width(110)
            TableColumn("Kind") { Text($0.kind).font(.caption.monospaced()) }.width(140)
            TableColumn("Event") { Text($0.title + ($0.detail.map { " — \($0)" } ?? "")).textSelection(.enabled) }
        }
    }
}

private struct NetworkPane: View {
    let tick: Int

    var body: some View {
        Table(HTTPTrace.entries.reversed()) {
            TableColumn("Time") { Text($0.date.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()) }.width(80)
            TableColumn("Service") { Text($0.service) }.width(100)
            TableColumn("Status") { entry in Badge("\(entry.status)", tone: entry.status < 300 || entry.status == 304 ? .success : entry.status < 500 ? .warning : .danger) }.width(60)
            TableColumn("Request") { Text("\($0.method) \($0.url)").font(.caption.monospaced()).textSelection(.enabled) }
            TableColumn("Size") { Text(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file)).font(.caption) }.width(70)
            TableColumn("Time (ms)") { Text("\($0.milliseconds)").font(.caption.monospaced()) }.width(70)
        }
        .id(tick)
    }
}

private struct ClaudePane: View {
    @Environment(ChatSession.self) private var chat

    var body: some View {
        let trace = chat.trace
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                metric("Requests", "\(trace.count)")
                metric("Input tokens", "\(trace.reduce(0) { $0 + $1.inputTokens })")
                metric("Output tokens", "\(trace.reduce(0) { $0 + $1.outputTokens })")
                metric("Cache reads", "\(trace.reduce(0) { $0 + $1.cacheReadTokens })")
            }
            .padding(12)
            Table(trace.reversed()) {
                TableColumn("Time") { Text($0.date.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()) }.width(80)
                TableColumn("Model") { Text($0.model).font(.caption.monospaced()) }.width(130)
                TableColumn("Stop") { Text($0.stopReason).font(.caption.monospaced()) }.width(80)
                TableColumn("In / Out") { Text("\($0.inputTokens) / \($0.outputTokens)").font(.caption.monospaced()) }.width(100)
                TableColumn("Cache r/w") { Text("\($0.cacheReadTokens) / \($0.cacheWriteTokens)").font(.caption.monospaced()) }.width(100)
                TableColumn("Tools") { Text($0.toolCalls.joined(separator: ", ")).font(.caption.monospaced()) }
                TableColumn("ms") { Text("\($0.milliseconds)").font(.caption.monospaced()) }.width(60)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ExtensionsPane: View {
    @Environment(ExtensionHost.self) private var host
    @State private var selected: String?

    var body: some View {
        HSplitView {
            List(host.extensions, id: \.id, selection: $selected) { item in
                SidebarRow(item: item).tag(item.id)
            }
            .frame(minWidth: 220)
            ScrollView {
                if let item = host.extensions.first(where: { $0.id == selected }) {
                    Text(Diagnostics.extensionInfo(item, host: host).jsonString(pretty: true))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text("Select an extension.").foregroundStyle(.secondary).padding()
                }
            }
        }
    }
}
