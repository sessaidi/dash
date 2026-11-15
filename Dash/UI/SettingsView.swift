import ClaudeCodeKit
@_spi(DashHost) import DashKit
@_spi(DashHost) import DashKitUI
import AppKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        @Bindable var host = host
        TabView(selection: $host.settingsTab) {
            Tab("Dashii", systemImage: "sparkles", value: "claude") {
                SegmentedPane(selection: $host.claudeSection, segments: [("setup", "Setup"), ("usage", "Usage")]) { section in
                    if section == "usage" { UsageView() } else { ClaudeSettings() }
                }
            }
            Tab("Automation", systemImage: "bolt", value: "automation") {
                SegmentedPane(selection: $host.automationSection, segments: [("rules", "Rules"), ("commands", "Commands"), ("hooks", "Hooks"), ("skills", "Skills"), ("agents", "Agents")]) { _ in
                    AutomationSettings(section: $host.automationSection)
                }
            }
            Tab("Persona", systemImage: "face.smiling", value: "persona") { PersonaSettings() }
            Tab("Plugins", systemImage: "puzzlepiece.extension", value: "plugins") { ExtensionList() }
            Tab("Marketplace", systemImage: "bag", value: "marketplace") {
                if let marketplace = host.ext(MarketplaceFeature.self) {
                    marketplace.settingsView().formStyle(.grouped)
                }
            }
            Tab("Updates", systemImage: "arrow.down.circle", value: "updates") { UpdateSettings() }
            Tab("Debug", systemImage: "ladybug", value: "debug") { DebugSettings() }
        }
        .frame(width: 860, height: 640)
    }
}

/// A tab split into segments (Claude: Setup | Usage; Plugins: Integrations | Features | Installed).
private struct SegmentedPane<Content: View>: View {
    @Binding var selection: String
    let segments: [(String, String)]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selection) {
                ForEach(segments, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 10)
            Divider()
            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ClaudeSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("claude CLI", text: $settings.claudePath, prompt: Text(settings.claudeExecutable?.path ?? "/opt/homebrew/bin/claude"))
                LabeledContent("Status") {
                    if let cli = settings.claudeExecutable {
                        Label("Found \(cli.path)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("Dashii's engine (Claude Code) not found — install it or set its path", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Dashii (chat, PR reviews, meeting summaries, agents and plugins) runs on Claude Code with your login (claude /login). Dash turns off the engine's own tools, settings and hooks and gives Dashii only Dash's tools.")
            }
            Section {
                Picker("Model", selection: $settings.model) {
                    ForEach(AppSettings.models, id: \.self) { Text($0) }
                }
                Picker("Effort", selection: $settings.effort) {
                    ForEach(AppSettings.efforts, id: \.self) { Text($0) }
                }
                Toggle("Ask before Dashii posts to GitHub or Jira, starts agents, or deletes", isOn: $settings.confirmWrites)
                Toggle(isOn: $settings.compactTools) {
                    Text("Work through DashQL statements")
                    Text("Dashii gets one `dash` tool instead of every tool: fewer tokens per message, same abilities and approvals.")
                }
                Toggle(isOn: $settings.compactResults) {
                    Text("Compact tool results")
                    Text("Results reach Dashii in a token-lean form instead of JSON (tables with field names once). Turn off to debug.")
                }
            }
            AlwaysAllowedSection()
            ClaudeStatusSection(executable: settings.claudeExecutable)
        }
        .formStyle(.grouped)
    }
}

/// Settings › Integrations / Features: every plugged extension of a layer with an on/off
/// switch; clicking one opens its detail (overview, configuration, storage).
/// Every installed integration and feature in one list; click one for its page (overview,
/// settings, AI, rules, storage). Plugin bundles (signatures, approvals) are one level deeper.
private struct ExtensionList: View {
    @Environment(ExtensionHost.self) private var host
    /// The page shown instead of the list (an extension id, or "__bundles"). Not a NavigationStack:
    /// its back button would join the Settings window's tab bar and shift the tabs by one.
    @State private var shown: String?

    var body: some View {
        if let shown {
            VStack(alignment: .leading, spacing: 0) {
                Button { self.shown = nil } label: { Label("Plugins", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if shown == "__bundles" {
                    PluginsSettings()
                } else if let item = host.extensions.first(where: { $0.id == shown }) {
                    ExtensionDetail(item: item)
                } else {
                    ContentUnavailableView("Not installed", systemImage: "puzzlepiece.extension")
                }
            }
            .onChange(of: host.managerSelection) { openRequested() }
        } else {
            list
        }
    }

    private var list: some View {
            Form {
                section(.integration, "Integrations", footer: "Connect an account. Turning one off hides its tools and pauses the features that require it.")
                section(.feature, "Features", footer: "Build on integrations: widgets, Dashii tools, agents. Turning one off keeps its data and settings.")
                if !host.extensionErrors.isEmpty {
                    Section("Problems") {
                        ForEach(host.extensionErrors, id: \.self) { Text($0).foregroundStyle(.red).font(.callout) }
                    }
                }
                Section {
                    row { Label("Plugin Files and Approvals", systemImage: "shippingbox") } open: { shown = "__bundles" }
                    HStack {
                        Button("Get More in the Marketplace…") { host.openManager("marketplace") }
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            // "Open settings of X" (from widgets, Home, the chat): straight to its page.
            .onAppear { openRequested() }
            .onChange(of: host.managerSelection) { openRequested() }
    }

    /// Where a plugin's extension came from ("Community", a company's registry, "Local");
    /// nil for what's built into Dash.
    private func source(of item: any DashExtension) -> String? {
        let plugin = host.plugins.first { record in
            if case .loaded(let ids) = record.state { ids.contains(item.id) } else { false }
        }
        guard let plugin else { return nil }
        return host.ext(MarketplaceFeature.self)?.sourceLabel(ofPlugin: plugin.id) ?? "Local"
    }

    private func openRequested() {
        guard let id = host.managerSelection, host.extensions.contains(where: { $0.id == id }) else { return }
        shown = id
        host.managerSelection = nil
    }

    /// A list row that opens a page: the whole row is clickable, with a chevron like a navigation link.
    private func row<Label: View>(@ViewBuilder _ label: () -> Label, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack {
                label()
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func section(_ layer: ExtensionLayer, _ title: String, footer: String) -> some View {
        let items = host.extensions.filter { $0.layer == layer && $0.id != "marketplace" }
        Section {
            if items.isEmpty { Text("None installed.").foregroundStyle(.secondary) }
            ForEach(items, id: \.id) { item in
                HStack {
                    row {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                SidebarRow(item: item)
                                if let source = source(of: item) { Badge(source, tone: MarketplaceFeature.tone(ofLabel: source)) }
                            }
                            Text("by \(item.author.name)\(item.summary.isEmpty ? "" : " · \(item.summary)")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } open: { shown = item.id }
                    Toggle("Enabled", isOn: Binding(get: { host.isEnabled(item) }, set: { host.setEnabled(item, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

private struct PluginsSettings: View {
    @Environment(ExtensionHost.self) private var host
    @State private var approvedNow: Set<String> = []

    var body: some View {
        Form {
            Section {
                if host.plugins.isEmpty { Text("No plugins found.").foregroundStyle(.secondary) }
                ForEach(host.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let icon = plugin.info?.icon { Image(systemName: icon).foregroundStyle(.secondary) }
                            Text(plugin.displayName).font(.callout.bold())
                            if plugin.info != nil { Text(plugin.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Badge(plugin.version)
                            Badge(plugin.bundled ? "Bundled" : "User", tone: plugin.bundled ? .info : .accent)
                            Spacer()
                            state(plugin)
                        }
                        if let description = plugin.info?.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                        if let requires = plugin.info?.requires, !requires.isEmpty {
                            Text("Needs \(requires.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(plugin.info?.author.map { "by \($0.name) · " } ?? "")\(plugin.signature) · sha256 \(plugin.sha256.prefix(12))…")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(plugin.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            } header: {
                Text("Plugins")
            } footer: {
                Text("Plugins load as soon as they're installed (from the Marketplace, or dropped into the Plugins folder and approved), pinned to their exact build. Updating or removing a loaded plugin finishes at the next launch.")
            }
            Section {
                HStack {
                    Button("Show Plugins Folder") { NSWorkspace.shared.open(PluginLoader.userFolder) }
                    Spacer()
                    if !approvedNow.isEmpty {
                        Button("Relaunch Dash") { relaunch() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func state(_ plugin: PluginRecord) -> some View {
        switch plugin.state {
        case .loaded(let ids):
            Badge("Loaded: \(ids.joined(separator: ", "))", tone: .success)
            if !plugin.bundled { Button("Remove Approval") { PluginLoader.revoke(plugin.id); approvedNow.insert(plugin.id) } }
        case .needsApproval:
            Button("Approve and Load…") { Task { await approve(plugin) } }
        case .failed(let message):
            Badge("Failed", tone: .danger).help(message)
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func approve(_ plugin: PluginRecord) async {
        let allowed = await host.permissionCenter.ask(
            icon: plugin.info?.icon ?? "shippingbox", title: "Load “\(plugin.displayName)” \(plugin.version)?",
            message: "Plugins run native code inside Dash with the same access as the app. Only approve plugins you trust.",
            details: (plugin.info?.details(installed: Set(host.extensions.map(\.id))) ?? [])
                + [.init(title: "Signed by", text: plugin.signature), .init(title: "SHA-256", text: plugin.sha256),
                   .init(title: "Location", text: plugin.url.path)],
            allowLabel: "Approve", denyLabel: "Cancel")
        if allowed {
            PluginLoader.approve(plugin)
            HotPlugins.shared.load(plugin.url)
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// Settings › Persona: Claude's name and voice, and the mascot.
private struct PersonaSettings: View {
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        @Bindable var persona = host.persona
        Form {
            Section {
                HStack(spacing: 16) {
                    DashiiView(direction: DashiiDirection(clip: .idle), scale: 0.42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(persona.name).font(.title2.bold())
                        Text(persona.tone.title).foregroundStyle(.secondary)
                    }
                }
                TextField("Name", text: $persona.name)
                Picker("Voice", selection: $persona.tone) {
                    ForEach(Persona.Tone.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Persona")
            } footer: {
                Text("Takes effect in the next conversation (New Chat).")
            }
            Section("Mascot") {
                Toggle("Show \(persona.name)", isOn: $persona.mascotVisible)
                Picker("Lives", selection: $persona.place) {
                    ForEach(Persona.Place.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Climb onto the frontmost window", isOn: $persona.climbsWindows)
                    .disabled(persona.place != .desktop)
                Toggle("Wander around the desktop when idle", isOn: $persona.roams)
                    .disabled(persona.place != .desktop || persona.climbsWindows)
                Toggle("\(GlobalHotKey.description) asks \(persona.name) from any app", isOn: $persona.hotKey)
                Toggle("Notify me (macOS notifications) when something needs me and Dash isn't in front", isOn: $persona.notifications)
                Picker("Tips", selection: $persona.chattiness) {
                    ForEach(Persona.Chattiness.allCases) { Text($0.title).tag($0) }
                }
                Button("Reset Position") {
                    DashDefaults.shared.set(0.0, forKey: "mascot.offsetX")
                    DashDefaults.shared.set(0.0, forKey: "mascot.offsetY")
                    DashDefaults.shared.removeObject(forKey: "NSWindow Frame DashDesktopMascot")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › Debug: turn on debug mode, then open the Debug window.
/// The installed version, the latest release, and installing it.
private struct UpdateSettings: View {
    @State private var updater = Updater.shared

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                LabeledContent("Installed", value: updater.currentVersion)
                TextField("Source", text: $updater.source, prompt: Text("owner/name or ~/path"))
                    .onSubmit { Task { await updater.check() } }
                status
                HStack {
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(updater.state == .checking || isInstalling)
                    if case .available(let release) = updater.state {
                        Button("Install \(release.version) and Relaunch") { Task { await updater.install(release) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!updater.canInstall)
                    }
                }
            } footer: {
                Text(updater.canInstall
                     ? "A GitHub repository (owner/name) or a local Dash checkout (~/code/perso/dash: the newest zip in its dist/). Dash gets the release, checks it, quits, replaces itself and opens again."
                     : "This is a debug build: it checks for releases but doesn't replace itself. Install a release build from scripts/release.sh.")
            }
            Section {
                Toggle("Check automatically", isOn: $updater.automaticChecks)
                if let last = updater.lastCheck {
                    LabeledContent("Last checked", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("At launch and every six hours. Private repositories use the GitHub CLI's login (`gh auth login`).")
            }
            if case .available(let release) = updater.state, !release.notes.isEmpty {
                Section("What's new in \(release.version)") {
                    Text(LocalizedStringKey(release.notes)).textSelection(.enabled)
                    if let page = release.page { Link("Open the release on GitHub", destination: page) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isInstalling: Bool {
        if case .installing = updater.state { true } else { false }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle: LabeledContent("Latest", value: "Not checked yet")
        case .checking: LabeledContent("Latest") { ProgressView().controlSize(.small) }
        case .upToDate: LabeledContent("Latest") { Label("Dash is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        case .available(let release): LabeledContent("Latest") { Label("\(release.version) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue) }
        case .installing(let step): LabeledContent("Installing") { HStack { ProgressView().controlSize(.small); Text(step) } }
        case .failed(let message): LabeledContent("Latest") { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }
}

private struct DebugSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Debug mode", isOn: $settings.debugMode)
                Button("Open Debug Window") { openWindow(id: "debug") }
                    .disabled(!settings.debugMode)
            } footer: {
                Text("Debug mode logs every HTTP request and Dashii turn, and adds the Debug window (logs, activity, network, Dashii, extensions, diagnostics export) to the sidebar and the Debug menu (⌥⌘D).")
            }
            SecretsSection()
            Section("Logs") {
                LabeledContent("In-app buffer", value: "\(DashLog.entries.count) entries")
                LabeledContent("Console.app", value: "subsystem \(DashLog.subsystem)")
            }
        }
        .formStyle(.grouped)
    }
}

/// Claude Code's version and login, `/usage`, and what Dash itself spent.
/// What the user answered "Always Allow" to, with a way to take it back.
struct AlwaysAllowedSection: View {
    @Query(sort: \PermissionGrant.grantedAt, order: .reverse) private var grants: [PermissionGrant]
    @Environment(\.modelContext) private var context

    var body: some View {
        Section {
            if grants.isEmpty {
                Text("Nothing yet. Choose “Always Allow” in a permission prompt to stop being asked for that action.")
                    .foregroundStyle(.secondary)
            }
            ForEach(grants) { grant in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(grant.label)
                        Text(grant.grantedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        context.delete(grant)
                        try? context.save()
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Always allowed")
        } footer: {
            Text("Deleting, running commands and anything that writes to another service always asks.")
        }
    }
}

struct ClaudeStatusSection: View {
    let executable: URL?
    private var usage: ClaudeUsage { .shared }

    var body: some View {
        Section {
            if let auth = usage.auth {
                LabeledContent("Account") {
                    Label(auth.loggedIn ? (auth.email ?? "Logged in") : "Not logged in — run claude /login",
                          systemImage: auth.loggedIn ? "checkmark.seal" : "xmark.seal")
                        .foregroundStyle(auth.loggedIn ? Color.primary : Color.orange)
                }
                if let plan = auth.subscriptionType { LabeledContent("Plan", value: plan.capitalized) }
                if let org = auth.orgName { LabeledContent("Organization", value: org) }
                if let method = auth.authMethod { LabeledContent("Signed in with", value: method) }
            }
            if let version = usage.version { LabeledContent("Engine", value: version) }
            if let error = usage.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if let refreshed = usage.refreshedAt {
                    Text("Updated \(refreshed.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if usage.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await usage.refresh(executable: executable) } }
                    .disabled(usage.isRefreshing)
            }
        } header: {
            Text("Status")
        }
        PlanLimitsSection(executable: executable)
        if let report = usage.report {
            ClaudeUsageReportView(report: report)
        }
        Section {
            let today = usage.totals(days: 1)
            LabeledContent("Dash today", value: "\(today.calls) requests · \(today.costUSD.formatted(.currency(code: "USD")))")
        } footer: {
            Text("Plan limits, charts, costs per source and model, and every request are under Usage.")
        }
        .task { if usage.refreshedAt == nil { await usage.refresh(executable: executable) } }
    }
}

/// `/usage`, one section per time window.
struct ClaudeUsageReportView: View {
    let report: ClaudeUsageReport

    var body: some View {
        ForEach(report.windows, id: \.label) { window in
            Section {
                HStack(spacing: 16) {
                    if let requests = window.requests { MetricView(requests.formatted(), label: "Requests") }
                    if let sessions = window.sessions { MetricView(sessions.formatted(), label: "Sessions") }
                }
                ForEach(window.tips, id: \.text) { tip in
                    HStack(alignment: .firstTextBaseline) {
                        ProgressView(value: Double(tip.percent), total: 100)
                            .frame(width: 70)
                        Text("\(tip.percent)%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                        Text(tip.text).font(.callout)
                    }
                }
                ForEach(window.top.keys.sorted(), id: \.self) { category in
                    LabeledContent("Top \(category)") {
                        Text(window.top[category]?.map { "\($0.text) \($0.percent)%" }.joined(separator: ", ") ?? "")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("/usage · \(window.label)")
            } footer: {
                if window.label == report.windows.last?.label {
                    Text(report.plan + ". Shares are approximate and cover sessions on this Mac only.")
                }
            }
        }
    }
}

