import DashKit
import DashKitUI
import SwiftUI

/// Debug › Extensions: one extension for a developer, readable. Its identity, what it needs, its
/// tools, functions, DashQL vocabulary, widgets, agents, presets, AI tasks and rules, and its
/// diagnostics as a collapsible JSON tree (copyable).
struct ExtensionInspector: View {
    let item: any DashExtension
    @Environment(ExtensionHost.self) private var host
    @State private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                TextField("Filter tools, datasets, widgets, agents…", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                if !item.requires.isEmpty || !item.optional.isEmpty {
                    section("Needs", "link") {
                        let unmet = Set(host.unmetRequirements(of: item))
                        chips(item.requires.map { ($0, unmet.contains($0) ? Tone.danger : Tone.success) }
                              + item.optional.map { ($0 + " (optional)", isReady($0) ? Tone.success : Tone.neutral) })
                    }
                }
                let tools = item.tools.filter(matches)
                if !tools.isEmpty {
                    section("Tools · \(tools.count)", "wrench.and.screwdriver") {
                        ForEach(tools, id: \.name) { tool in
                            row(tool.name, detail: tool.description) {
                                if tool.writesRemotely { Badge("writes remotely", tone: .danger) }
                                else if tool.callsService { Badge("extensions only", tone: .neutral) }
                                else if tool.requiresApproval { Badge("asks first", tone: .warning) }
                                else { Badge("read", tone: .neutral) }
                            }
                        }
                    }
                }
                let functions = item.functions.filter { matches($0.name + $0.summary) }
                if !functions.isEmpty {
                    section("Functions · \(functions.count)", "function") {
                        ForEach(functions, id: \.name) { row($0.name, detail: $0.summary) { EmptyView() } }
                    }
                }
                let datasets = item.datasets.filter { matches($0.name + $0.summary) }
                if !datasets.isEmpty {
                    section("DashQL datasets · \(datasets.count)", "tablecells") {
                        ForEach(datasets, id: \.name) { dataset in
                            VStack(alignment: .leading, spacing: 4) {
                                row("from " + dataset.name, detail: dataset.summary) {
                                    if !dataset.aliases.isEmpty { Badge("also " + dataset.aliases.joined(separator: ", "), tone: .info) }
                                }
                                FlowLine(items: dataset.fields.map { "\($0.name): \($0.type.rawValue)" })
                            }
                        }
                    }
                }
                let verbs = item.verbs.filter { matches($0.usage + $0.summary) }
                if !verbs.isEmpty {
                    section("DashQL statements · \(verbs.count)", "text.word.spacing") {
                        ForEach(verbs, id: \.usage) { verb in row(verb.usage, detail: verb.summary) { Badge("→ \(verb.tool)", tone: .neutral) } }
                    }
                }
                let widgets = item.widgets.filter { matches($0.kind + $0.displayName + $0.summary) }
                if !widgets.isEmpty {
                    section("Widgets · \(widgets.count)", "square.grid.2x2") {
                        ForEach(widgets) { widget in
                            row(widget.displayName, detail: widget.summary) {
                                Badge(widget.kind, tone: .neutral)
                                Badge(widget.defaultSize.rawValue, tone: .info)
                                if !widget.actions.isEmpty { Badge("\(widget.actions.count) actions", tone: .accent) }
                            }
                        }
                    }
                }
                let agents = item.agents.filter { matches($0.id + " " + $0.name + " " + $0.summary) }
                if !agents.isEmpty {
                    section("Agents · \(agents.count)", "person.badge.shield.checkmark") {
                        ForEach(agents) { agent in
                            row("\(item.id).\(agent.id)", detail: agent.summary) {
                                Badge(agent.access == .readOnly ? "read-only" : "acts with approval", tone: agent.access == .readOnly ? .success : .warning)
                                if let minutes = agent.schedule.everyMinutes { Badge("every \(minutes) min", tone: .neutral) }
                                ForEach(agent.schedule.events, id: \.self) { Badge("on \($0)", tone: .info) }
                            }
                        }
                    }
                }
                let presets = item.hookPresets.filter { matches($0.id + " " + $0.name) }
                if !presets.isEmpty {
                    section("Hook presets · \(presets.count)", "bolt") {
                        ForEach(presets, id: \.id) { preset in row(preset.name, detail: preset.id) { EmptyView() } }
                    }
                }
                let aiTasks = item.aiTasks.filter { matches($0.title + " " + $0.summary) }
                if !aiTasks.isEmpty {
                    section("AI tasks · \(aiTasks.count)", "sparkles") {
                        ForEach(aiTasks, id: \.id) { task in
                            row(task.title, detail: task.summary) {
                                Badge(task.defaultModel.displayName, tone: .accent)
                                if let effort = task.defaultEffort { Badge(effort.rawValue, tone: .neutral) }
                            }
                        }
                    }
                }
                let rules = item.rules.rules.filter { matches($0.text) }
                if !rules.isEmpty {
                    section("Default rules · \(rules.count)", "list.bullet.rectangle") {
                        ForEach(rules) { rule in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Label(rule.kind.title, systemImage: rule.kind.systemImage).font(.caption2.weight(.semibold)).frame(width: 70, alignment: .leading)
                                Text(rule.text).font(.caption).foregroundStyle(rule.enabled ? .primary : .secondary)
                            }
                        }
                    }
                }
                section("Diagnostics", "stethoscope") {
                    JSONTree(value: Diagnostics.extensionInfo(item, host: host))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage).font(.title).foregroundStyle(.tint)
                .frame(width: 46, height: 46).background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name).font(.title3.bold())
                    Badge(item.layer == .integration ? "integration" : "feature", tone: .accent)
                    Badge(ExtensionHost.builtInIDs.contains(item.id) ? "built in" : "plugin", tone: .neutral)
                    StatusDot(host.isEnabled(item) ? .success : .neutral)
                }
                HStack(spacing: 10) {
                    Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
                    Text("v" + item.metadata.version).font(.caption).foregroundStyle(.secondary)
                    if let minimum = item.metadata.minimumDashKit { Text("DashKit ≥ \(minimum)").font(.caption).foregroundStyle(.secondary) }
                }
                if !item.metadata.summary.isEmpty { Text(item.metadata.summary).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Copy JSON", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Diagnostics.extensionInfo(item, host: host).jsonString(pretty: true), forType: .string)
            }
        }
    }

    /// Installed, on, and (integrations) connected.
    private func isReady(_ id: String) -> Bool {
        if let integration = host.integration(id) { return host.isEnabled(integration) && integration.isConnected }
        return host.extensions.first { $0.id == id }.map { host.isEnabled($0) } ?? false
    }

    private func matches(_ tool: DashiiTool) -> Bool { matches(tool.name + " " + tool.description) }
    private func matches(_ text: String) -> Bool { filter.isEmpty || text.localizedCaseInsensitiveContains(filter) }

    private func section<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
    }

    private func row<Trailing: View>(_ name: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.callout.monospaced().weight(.medium)).textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            HStack(spacing: 4) { trailing() }
        }
    }

    private func chips(_ items: [(String, Tone)]) -> some View {
        HStack(spacing: 6) { ForEach(items, id: \.0) { Badge($0.0, tone: $0.1) } }
    }
}

/// Short values wrapped on as many lines as needed.
private struct FlowLine: View {
    let items: [String]

    var body: some View {
        Text(items.joined(separator: "  ·  ")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

/// JSON as a collapsible tree: keys, typed values in colour, counts on containers.
struct JSONTree: View {
    let value: JSONValue
    var key: String?
    var expanded = true

    var body: some View {
        switch value {
        case .object(let fields):
            container(summary: "{\(fields.count)}") {
                ForEach(fields.sorted { $0.key < $1.key }, id: \.key) { JSONTree(value: $0.value, key: $0.key, expanded: false) }
            }
        case .array(let items):
            container(summary: "[\(items.count)]") {
                ForEach(Array(items.enumerated()), id: \.offset) { JSONTree(value: $1, key: "\($0)", expanded: false) }
            }
        default:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let key { Text(key).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Text(scalar).font(.caption.monospaced()).foregroundStyle(color).textSelection(.enabled).lineLimit(4)
            }
        }
    }

    @ViewBuilder private func container<Content: View>(summary: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        if key == nil {
            VStack(alignment: .leading, spacing: 3) { content() }
        } else {
            JSONDisclosure(title: key ?? "", summary: summary, expanded: expanded, content: content)
        }
    }

    private var scalar: String {
        switch value {
        case .string(let text): "\"\(text)\""
        case .null: "null"
        default: value.jsonString()
        }
    }

    private var color: Color {
        switch value {
        case .string: .red.opacity(0.85)
        case .number: .blue
        case .bool: .purple
        default: .secondary
        }
    }
}

private struct JSONDisclosure<Content: View>: View {
    let title: String
    let summary: String
    @State var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(title: String, summary: String, expanded: Bool, content: @escaping () -> Content) {
        self.title = title
        self.summary = summary
        _expanded = State(initialValue: expanded)
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) { content() }.padding(.leading, 6)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.caption.monospaced().weight(.semibold))
                Text(summary).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
    }
}
