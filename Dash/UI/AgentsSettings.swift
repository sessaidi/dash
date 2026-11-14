import DashKit
import SwiftData
import SwiftUI

/// Settings › Automation › Agents: every background agent (yours and plugins'), with on/off,
/// schedule, Run Now and the latest reports; create and edit your own.
struct AgentsSettings: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(\.modelContext) private var context
    @State private var hub = AgentHub.shared
    @State private var editing: CustomAgent?
    @State private var selected: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selected) {
                Section("Agents") {
                    ForEach(hub.entries, id: \.id) { entry in
                        HStack {
                            Image(systemName: entry.agent.systemImage).foregroundStyle(.tint).frame(width: 18)
                            VStack(alignment: .leading) {
                                Text(entry.agent.name)
                                Text(entry.agent.role.isEmpty ? entry.owner.name : entry.agent.role).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(AgentRowsView.color(hub.reports(entry.id, limit: 1).first)).frame(width: 8, height: 8)
                        }
                        .tag(entry.id)
                    }
                }
            }
            .frame(width: 230)
            .safeAreaInset(edge: .bottom) {
                Menu("New Agent", systemImage: "plus") {
                    Button("Blank") { create(nil) }
                    Divider()
                    ForEach(CustomAgent.templates, id: \.name) { template in
                        Button(template.name) { create(template.name) }
                    }
                }
                .padding(8)
            }
            Divider()
            if let id = selected, let entry = hub.entry(id) {
                AgentDetail(entry: entry, custom: custom(id), onEdit: { editing = $0 }, onDelete: delete)
                    .id(id)
            } else {
                ContentUnavailableView("Agents", systemImage: "person.2.badge.gearshape",
                                       description: Text("Agents work in the background with a role, the integrations you allow and a scope. Create one, or install plugins that bring theirs."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editing) { AgentEditor(agent: $0) }
    }

    private func custom(_ id: String) -> CustomAgent? {
        guard id.hasPrefix("agents-studio.") else { return nil }
        let uuid = UUID(uuidString: String(id.dropFirst("agents-studio.".count)))
        return (try? context.fetch(FetchDescriptor<CustomAgent>()))?.first { $0.id == uuid }
    }

    private func create(_ template: String?) {
        let agent = CustomAgent()
        if let template = CustomAgent.templates.first(where: { $0.name == template }) {
            agent.name = template.name
            agent.role = template.role
            agent.specialities = template.specialities
            agent.systemImage = template.icon
            agent.instructions = template.instructions
            agent.integrations = template.integrations
            agent.everyMinutes = template.every
        }
        context.insert(agent)
        try? context.save()
        editing = agent
        selected = "agents-studio.\(agent.id.uuidString)"
    }

    private func delete(_ agent: CustomAgent) {
        context.delete(agent)
        try? context.save()
        selected = nil
    }
}

private struct AgentDetail: View {
    let entry: AgentHub.Entry
    let custom: CustomAgent?
    let onEdit: (CustomAgent) -> Void
    let onDelete: (CustomAgent) -> Void
    @Environment(ExtensionHost.self) private var host
    @State private var hub = AgentHub.shared
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Role", value: entry.agent.role.isEmpty ? "—" : entry.agent.role)
                if !entry.agent.specialities.isEmpty { LabeledContent("Specialities", value: entry.agent.specialities.joined(separator: ", ")) }
                LabeledContent("Access", value: entry.agent.access == .readOnly ? "Read-only" : "Can act (asks you each time)")
                LabeledContent("Tools", value: AgentHub.tools(for: entry.agent, in: host).map(\.name).joined(separator: ", ").nonEmpty ?? "None — check its integrations are installed")
                if !entry.agent.scope.isEmpty { LabeledContent("Scope", value: entry.agent.scope) }
                LabeledContent("From", value: custom == nil ? entry.owner.name : "You")
            } header: {
                HStack {
                    Label(entry.agent.name, systemImage: entry.agent.systemImage).font(.title3.bold())
                    Spacer()
                    if let custom {
                        Button("Edit…") { onEdit(custom) }
                        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(custom) }.labelStyle(.iconOnly)
                    }
                }
            }
            Section("When") {
                Toggle("Enabled", isOn: Binding(get: { hub.isEnabled(entry) }, set: { hub.setEnabled(entry, $0) }))
                Stepper(value: Binding(get: { hub.interval(entry) ?? 0 }, set: { hub.setInterval(entry, $0) }), in: 0...1440, step: 5) {
                    Text((hub.interval(entry) ?? 0) == 0 ? "Not scheduled" : "Every \(hub.interval(entry)!) min")
                }
                if !entry.agent.schedule.events.isEmpty {
                    LabeledContent("Also on", value: entry.agent.schedule.events.joined(separator: ", "))
                }
                HStack {
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    Button {
                        Task {
                            do { _ = try await hub.run(entry.id, reason: "manual"); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        if hub.running.contains(entry.id) { ProgressView().controlSize(.small) } else { Text("Run Now") }
                    }
                    .disabled(hub.running.contains(entry.id))
                }
            }
            Section("Reports") {
                let reports = hub.reports(entry.id, limit: 20)
                if reports.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                ForEach(reports) { report in
                    DisclosureGroup {
                        ForEach(report.findings) { finding in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(finding.severity.rawValue.uppercased()) · \(finding.title)").font(.callout.bold())
                                if !finding.target.isEmpty { Text(finding.target).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                if !finding.detail.isEmpty { Text(finding.detail).font(.callout) }
                                if !finding.suggestion.isEmpty { Text("→ \(finding.suggestion)").font(.callout).foregroundStyle(.secondary) }
                            }
                            .textSelection(.enabled)
                        }
                    } label: {
                        HStack {
                            Circle().fill(AgentRowsView.color(report)).frame(width: 8, height: 8)
                            Text(report.summary).lineLimit(1)
                            Spacer()
                            Text(report.startedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Creates or edits a custom agent.
private struct AgentEditor: View {
    @Bindable var agent: CustomAgent
    @Environment(ExtensionHost.self) private var host
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private static let icons = ["person.badge.shield.checkmark", "server.rack", "shippingbox", "arrow.triangle.pull", "checklist",
                                "ladybug", "flame", "chart.line.uptrend.xyaxis", "lock.shield", "bolt.heart", "doc.text.magnifyingglass", "cloud"]

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section("Who") {
                TextField("Name", text: $agent.name)
                TextField("Role", text: $agent.role, prompt: Text("e.g. Site reliability engineer"))
                TextField("Specialities", text: Binding(get: { agent.specialities.joined(separator: ", ") },
                                                        set: { agent.specialities = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                          prompt: Text("Kubernetes, PostgreSQL, incident response"))
                Picker("Icon", selection: $agent.systemImage) {
                    ForEach(Self.icons, id: \.self) { Image(systemName: $0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Section {
                TextField("What it does", text: $agent.instructions, prompt: Text("What to check, what counts as a problem, what to report."), axis: .vertical)
                    .lineLimit(4...10)
                TextField("Scope", text: $agent.scope, prompt: Text("e.g. only the prod namespace; only repos under acme/"), axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("Instructions")
            }
            Section {
                ForEach(host.extensions.filter { host.isEnabled($0) && !$0.tools.isEmpty && $0.id != "agents-studio" }, id: \.id) { item in
                    Toggle(isOn: Binding(get: { agent.integrations.contains(item.id) },
                                         set: { on in if on { agent.integrations.append(item.id) } else { agent.integrations.removeAll { $0 == item.id } } })) {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.tools.filter { agent.canAct || !$0.requiresApproval }.map(\.name).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Picker("Access", selection: $agent.canAct) {
                    Text("Read-only: observe and report").tag(false)
                    Text("Can act: may change things, asks you each time").tag(true)
                }
            } header: {
                Text("Integrations it may use")
            }
            Section("When") {
                Stepper(value: $agent.everyMinutes, in: 0...1440, step: 5) {
                    Text(agent.everyMinutes == 0 ? "Not scheduled (on demand or on events)" : "Every \(agent.everyMinutes) min")
                }
                let declared = host.extensions.flatMap(\.events).map(\.kind).sorted()
                Menu("On events: \(agent.events.isEmpty ? "none" : agent.events.joined(separator: ", "))") {
                    ForEach(declared, id: \.self) { kind in
                        Toggle(kind, isOn: Binding(get: { agent.events.contains(kind) },
                                                   set: { on in if on { agent.events.append(kind) } else { agent.events.removeAll { $0 == kind } } }))
                    }
                }
                Picker("Model", selection: $agent.model) {
                    ForEach([ClaudeModel.sonnet, .haiku, .opus]) { Text($0.displayName).tag($0.rawValue) }
                }
            }
        }
        .formStyle(.grouped)
        Divider()
        // Outside the form so they stay visible however tall the form is.
        HStack {
            if agent.name.trimmingCharacters(in: .whitespaces).isEmpty || agent.instructions.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("A name and what it does are needed.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                context.rollback()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Done") {
                try? context.save()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(agent.name.trimmingCharacters(in: .whitespaces).isEmpty || agent.instructions.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        }
        .frame(width: 560)
        .frame(minHeight: 360, idealHeight: 560, maxHeight: 620)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
