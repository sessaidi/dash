@_spi(DashHost) import DashKit
@_spi(DashHost) import DashKitUI
import SwiftUI

extension DashExtension {
    var sourceLabel: String {
        ExtensionHost.builtInIDs.contains(id) ? "Built in" : "Plugin"
    }
}

/// Sidebar row with a status dot.
struct SidebarRow: View {
    let item: any DashExtension
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        HStack {
            Label(item.name, systemImage: item.systemImage)
            Spacer()
            StatusDot(status.tone, help: status.help)
        }
    }

    private var status: (tone: Tone, help: String) {
        if !host.isEnabled(item) { return (.neutral, "Turned off") }
        if let integration = item as? any Integration, item.layer == .integration {
            let state = integration.connectionState
            return (state.tone, state.title)
        }
        let missing = host.unmetRequirements(of: item)
        return missing.isEmpty ? (.success, "Ready") : (.warning, "Needs \(missing.joined(separator: ", "))")
    }
}

struct ExtensionDetail: View {
    let item: any DashExtension
    @Environment(ExtensionHost.self) private var host
    @State private var tab = Tab.overview

    enum Tab: String, CaseIterable { case overview = "Overview", settings = "Settings", ai = "AI", rules = "Rules", storage = "Storage" }

    private var tabs: [Tab] { Tab.allCases.filter { $0 != .ai || !item.aiTasks.isEmpty || !item.agents.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .padding(.bottom, 8)
            Divider()
            switch tab {
            case .overview: Overview(item: item)
            case .settings: item.settingsView().formStyle(.grouped)
            case .ai: AISettingsView(scope: .extension(item.id), tasks: item.aiTasks + item.agents.map(\.task).filter { task in !item.aiTasks.contains { $0.id == task.id } })
            case .rules: RulesEditor(only: item.id)
            case .storage: StorageView(item: item)
            }
        }
        .navigationTitle(item.name)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.systemImage)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name).font(.title2.bold())
                    Badge(item.layer.rawValue, tone: item.layer == .integration ? .info : .accent)
                    Badge(item.sourceLabel)
                }
                AuthorLine(author: item.author)
                if !item.summary.isEmpty { Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if let integration = item as? any Integration, item.layer == .integration {
                    ConnectionStatusLabel(integration.connectionState).font(.callout)
                } else {
                    let missing = host.unmetRequirements(of: item)
                    Text(!host.isEnabled(item) ? "Turned off" : missing.isEmpty ? "Ready" : "Needs \(missing.map { host.integration($0)?.name ?? $0 }.joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.id != "marketplace" {
                Toggle("Enabled", isOn: Binding(get: { host.isEnabled(item) }, set: { host.setEnabled(item, $0) }))
                    .toggleStyle(.switch)
            }
        }
        .padding(20)
    }
}

private struct Overview: View {
    let item: any DashExtension
    @Environment(ExtensionHost.self) private var host
    @State private var added: Set<String> = []

    var body: some View {
        Form {
            if item.layer == .integration {
                let users = host.features(using: item.id)
                Section("Used by") {
                    if users.isEmpty { Text("No feature uses this integration yet.").foregroundStyle(.secondary) }
                    ForEach(users, id: \.id) { feature in
                        Button { host.managerSelection = feature.id } label: {
                            ItemRow(feature.name, subtitle: feature.requires.contains(item.id) ? "requires it" : "uses it when connected",
                                    leading: { Image(systemName: feature.systemImage).frame(width: 20) },
                                    trailing: { Image(systemName: "chevron.right").foregroundStyle(.tertiary) })
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                requirements("Requires", item.requires)
                requirements("Optional", item.optional)
            }
            if !item.widgets.isEmpty {
                Section {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(item.widgets) { widget in
                                VStack(alignment: .leading, spacing: 6) {
                                    SizedWidgetPreview(type: widget)
                                    Text(widget.displayName).font(.callout.bold())
                                    Text(widget.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        .frame(width: WidgetMiniature.maxSize.width, alignment: .leading)
                                    if added.contains(widget.kind) {
                                        Badge("Added", tone: .success, systemImage: "checkmark")
                                    } else {
                                        Button("Add to Dashboard") {
                                            if (try? host.dashboard.add(kind: widget.kind)) != nil { added.insert(widget.kind) }
                                        }
                                        .disabled(!host.isEnabled(item))
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("Previews use sample data; switch sizes to see each layout. Resize and configure widgets once they're on the dashboard.")
                }
            }
            let tools = item.tools
            Section {
                if tools.isEmpty { Text(item.layer == .integration && !((item as? any Integration)?.isConnected ?? false) ? "Connect to see its tools." : "None.").foregroundStyle(.secondary) }
                ForEach(tools, id: \.name) { tool in
                    ItemRow(tool.name, subtitle: tool.description, monospacedTitle: true) {
                        if tool.requiresApproval { Badge("asks first", tone: .warning) }
                    }
                    .help(tool.description)
                }
            } header: {
                Text("Dashii tools")
            } footer: {
                if !host.unmetRequirements(of: item).isEmpty || !host.isEnabled(item) {
                    Text("Dashii can't use these until the feature is on and its integrations are connected.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func requirements(_ title: String, _ ids: [String]) -> some View {
        if !ids.isEmpty {
            Section(title) {
                ForEach(ids, id: \.self) { id in
                    // An integration or a feature: either can be required.
                    let installed = host.extensions.first { $0.id == id }
                    let integration = host.integration(id)
                    Button { host.managerSelection = id } label: {
                        ItemRow(installed?.name ?? id,
                                leading: { Image(systemName: installed?.systemImage ?? "questionmark.square").frame(width: 20) },
                                trailing: {
                                    if let integration {
                                        ConnectionStatusLabel(integration.connectionState).font(.caption)
                                    } else if let installed {
                                        if !host.isEnabled(installed) {
                                            Badge("turned off", tone: .warning)
                                        } else if !host.unmetRequirements(of: installed).isEmpty {
                                            Badge("needs setup", tone: .warning)
                                        } else {
                                            Badge("installed", tone: .success)
                                        }
                                    } else {
                                        Badge("not installed", tone: .danger)
                                    }
                                })
                    }
                    .buttonStyle(.plain)
                    .disabled(installed == nil)
                }
            }
        }
    }
}

private struct StorageView: View {
    let item: any DashExtension
    @Environment(ExtensionHost.self) private var host
    @State private var refresh = 0
    @State private var confirmData = false
    @State private var confirmReset = false

    var body: some View {
        let preferences = host.preferences(for: item)
        let data = host.dataSummary(for: item)
        Form {
            Section {
                if item.secretKeys.isEmpty { Text("No secrets.").foregroundStyle(.secondary) }
                ForEach(item.secretKeys, id: \.key) { secret in
                    let stored = item.secrets?.contains(secret.key) ?? false
                    LabeledContent(secret.label) {
                        HStack {
                            Badge(stored ? "Stored" : "Not set", tone: stored ? .success : .neutral)
                            if stored {
                                Button("Remove", role: .destructive) { item.secrets?.write(secret.key, nil); refresh += 1 }
                            }
                        }
                    }
                }
            } header: {
                Text("Secrets")
            } footer: {
                Text(Keychain.backend.location(account: "\(item.secrets?.extensionID ?? item.id).<key>") + " Change in Settings › Debug › Tokens.")
            }
            Section("Preferences") {
                LabeledContent("Stored values", value: "\(preferences.storedKeys.count)")
                if !preferences.storedKeys.isEmpty {
                    DisclosureGroup("Keys") {
                        ForEach(preferences.storedKeys, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
            Section("Data") {
                if data.isEmpty { Text("This extension stores no records.").foregroundStyle(.secondary) }
                ForEach(data, id: \.model) { entry in LabeledContent(entry.model, value: "\(entry.count) records") }
                if !data.isEmpty {
                    Button("Delete All Data…", role: .destructive) { confirmData = true }
                        .disabled(data.allSatisfy { $0.count == 0 })
                }
            }
            Section {
                Button("Reset Secrets and Preferences…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .confirmationDialog("Delete \(item.name)'s data?", isPresented: $confirmData) {
            Button("Delete", role: .destructive) { host.deleteData(for: item); refresh += 1 }
        } message: {
            Text("Synced records are fetched again on the next refresh; local-only records (reviews, transcripts, agent history) are gone for good.")
        }
        .confirmationDialog("Reset \(item.name)?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { host.resetStorage(for: item); refresh += 1 }
        } message: {
            Text("Removes its secrets and preferences. You'll need to set it up again.")
        }
    }
}

/// A widget rendered at its preset size with its default config, scaled down for previews.
/// It draws the widget's sample preview (never live data) and doesn't respond to clicks.
/// A widget's preview with its allowed sizes to switch between.
struct SizedWidgetPreview: View {
    let type: WidgetType
    @State private var size: WidgetSize?

    var body: some View {
        let sizes = WidgetMiniature.sizes(of: type)
        VStack(alignment: .leading, spacing: 6) {
            // One scale for every size, so a larger size shows more room, as on the dashboard.
            WidgetMiniature(type: type, size: size ?? type.defaultSize, scale: 0.5)
                .animation(.snappy(duration: 0.2), value: size)
            if sizes.count > 1 {
                Picker("Size", selection: Binding(get: { size ?? type.defaultSize }, set: { size = $0 })) {
                    ForEach(sizes, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 300)
            }
        }
    }
}

struct WidgetMiniature: View {
    static let maxSize = CGSize(width: 260, height: 190)
    let type: WidgetType
    let size: WidgetSize
    private let config: JSONValue

    /// nil fits the preview in `maxSize`; a number draws it at that scale (sizes then differ on screen).
    let scale: CGFloat?

    init(type: WidgetType, size: WidgetSize? = nil, scale: CGFloat? = nil) {
        self.type = type
        self.size = size ?? type.defaultSize
        self.scale = scale
        config = type.defaultConfig
    }

    /// The preset sizes the widget allows (its size limits), smallest first.
    static func sizes(of type: WidgetType) -> [WidgetSize] {
        let limits = type.sizeLimits
        let allowed = WidgetSize.allCases.filter { size in
            let cells = size.cells
            return (limits.minW...max(limits.minW, limits.maxW)).contains(cells.w) && (limits.minH...max(limits.minH, limits.maxH)).contains(cells.h)
        }
        return allowed.isEmpty ? [type.defaultSize] : allowed
    }

    var body: some View {
        let cells = size.cells
        // Same geometry as the dashboard grid at a typical column width.
        let full = CGSize(width: CGFloat(cells.w) * 80 + CGFloat(cells.w - 1) * 16,
                          height: CGFloat(cells.h) * 40 + CGFloat(cells.h - 1) * 16)
        let scale = self.scale ?? min(Self.maxSize.width / full.width, Self.maxSize.height / full.height, 0.75)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: type.systemImage).foregroundStyle(.secondary)
                Text(type.displayName).font(.headline).lineLimit(1)
                Spacer()
            }
            // Sample data only: a preview never calls the widget's live content (no network, no accounts).
            Group {
                if let preview = type.preview { preview(config) } else { WidgetPlaceholder(type: type) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Previews adapt to the size like the real widget does.
            .measuresWidgetLayout()
        }
        .padding(14)
        .frame(width: full.width, height: full.height)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: full.width * scale, height: full.height * scale, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(type.displayName) widget")
    }
}

/// A neutral stand-in for widgets without a sample preview: skeleton rows under the summary.
struct WidgetPlaceholder: View {
    let type: WidgetType

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 8) {
                    Circle().fill(.quaternary).frame(width: 14, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .frame(width: [150, 110, 170, 90][row], height: 10)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.7)).frame(width: 36, height: 10)
                }
            }
            Spacer(minLength: 0)
            Text(type.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.top, 4)
    }
}

/// "by Platform team · website · contact".
struct AuthorLine: View {
    let author: ExtensionAuthor

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            Text("by \(author.name)").foregroundStyle(.secondary)
            if let link = author.url.flatMap(URL.init(string:)), link.scheme == "https" {
                Link("Website", destination: link)
            }
            if let email = author.email, let mail = URL(string: "mailto:\(email)") {
                Link("Contact", destination: mail)
            }
        }
        .font(.caption)
    }
}

/// Lists the features built on an integration, for its settings pane.
struct FeaturesUsingSection: View {
    let integrationID: String
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        let features = host.features(using: integrationID)
        if !features.isEmpty {
            Section("Features using this integration") {
                ForEach(features, id: \.id) { feature in
                    Label(feature.name, systemImage: feature.systemImage)
                }
            }
        }
    }
}
