import DashKit
import DashKitUI
import SwiftUI

/// The AI tab of a widget or an extension: for each task it declares, the model (from the
/// ones the task allows), the effort, an on/off switch when the task has one, and its prompt
/// templates with insertable `{{variables}}`.
struct AISettingsView: View {
    let scope: AIScope
    let tasks: [AITask]
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        let settings = host.aiSettings(scope, tasks: tasks)
        Form {
            ForEach(tasks) { task in
                Section {
                    if let fallback = task.enabledByDefault {
                        Toggle("Allowed", isOn: binding(task) { $0.enabled ?? fallback } set: { $0.enabled = $1 })
                    }
                    if settings.isEnabled(task.id) {
                        Picker("Model", selection: binding(task) { _ in settings.model(task.id) } set: { $0.model = $1 }) {
                            ForEach(task.models) { model in
                                Text(model == task.defaultModel ? "\(model.displayName) (default)" : model.displayName).tag(model)
                            }
                        }
                        Text(settings.model(task.id).note).font(.caption).foregroundStyle(.secondary)
                        if !task.efforts.isEmpty {
                            Picker("Effort", selection: binding(task) { _ in settings.effort(task.id) ?? task.efforts[0] } set: { $0.effort = $1 }) {
                                ForEach(task.efforts) { Text($0.displayName).tag($0) }
                            }
                        }
                        ForEach(task.templates) { template in
                            TemplateEditor(template: template, text: binding(task) { $0.templates[template.id] ?? template.defaultText } set: { choice, text in
                                choice.templates[template.id] = text == template.defaultText ? nil : text
                            })
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                        Text(task.summary).font(.caption).foregroundStyle(.secondary).textCase(nil)
                    }
                } footer: {
                    if host.aiChoices(scope)[task.id] != nil {
                        HStack {
                            Spacer()
                            Button("Reset to Defaults") { host.setAIChoice(nil, task: task.id, scope: scope) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A binding onto one field of a task's saved choice; writes save straight away.
    private func binding<Value>(_ task: AITask, get: @escaping (AITaskChoice) -> Value,
                                set: @escaping (inout AITaskChoice, Value) -> Void) -> Binding<Value> {
        Binding(
            get: { get(host.aiChoices(scope)[task.id] ?? AITaskChoice()) },
            set: { value in
                var choice = host.aiChoices(scope)[task.id] ?? AITaskChoice()
                set(&choice, value)
                host.setAIChoice(choice == AITaskChoice() ? nil : choice, task: task.id, scope: scope)
            })
    }
}

/// One prompt template: an editor plus chips that insert its `{{variables}}`.
private struct TemplateEditor: View {
    let template: AITemplate
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(template.title)
                Spacer()
                if text != template.defaultText {
                    Button("Default") { text = template.defaultText }.buttonStyle(.link).font(.caption)
                }
            }
            if template.multiline {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 90, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
            } else {
                TextField(template.title, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .labelsHidden()
            }
            if !template.variables.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(template.variables.keys.sorted(), id: \.self) { name in
                            Button { text += "{{\(name)}}" } label: {
                                Text("{{\(name)}}").font(.caption.monospaced())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(template.variables[name] ?? name)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
