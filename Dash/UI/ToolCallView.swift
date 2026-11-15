import DashKit
import SwiftUI

/// A tool call in the chat, readable: a one-line summary, then each `dash` statement with what
/// it did, or the tool's input as fields. Raw JSON only on demand.
struct ToolCallView: View {
    let name: String
    let input: String
    let result: String?
    let isError: Bool
    @State private var raw = false

    private var inputJSON: JSONValue? { try? JSONValue.parse(input) }
    private var resultJSON: JSONValue? { result.flatMap { try? CompactFormat.decode($0) } }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if raw {
                    CodeText(input)
                    if let result { CodeText(result).foregroundStyle(isError ? .red : .primary) }
                } else if name == "dash", let script = inputJSON?["script"]?.string {
                    ForEach(Array(steps(script).enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                } else {
                    if let fields = inputJSON?.object, !fields.isEmpty { FieldsView(fields: fields) }
                    if let result { ResultText(text: result, isError: isError) }
                }
                Button(raw ? "Readable view" : "Raw JSON") { raw.toggle() }.buttonStyle(.link).font(.caption)
            }
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: result == nil ? "hammer" : isError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(result == nil ? Color.secondary : isError ? .red : .green)
                Text(summary).font(.caption).lineLimit(1).truncationMode(.tail)
                if result == nil { ProgressView().controlSize(.mini) }
            }
        }
    }

    /// "dash · 3 steps: notes_create “PAPI · Architecture”, …" or the tool and its main argument.
    private var summary: String {
        if name == "dash", let script = inputJSON?["script"]?.string {
            let statements = DashScript.statements(script)
            let first = statements.first.map(Self.headline) ?? ""
            return statements.count == 1 ? first : "\(statements.count) steps · \(first)…"
        }
        let main = ["title", "name", "query", "key", "id", "path", "symptom"].lazy.compactMap { inputJSON?[$0]?.string }.first
        return main.map { "\(name) · \($0)" } ?? name
    }

    /// A statement's verb and its title or first argument, without the long options.
    static func headline(_ statement: String) -> String {
        var words = DashArgs(statement)
        guard let verb = words.word() else { return statement }
        let options = words.options()
        let subject = ["title", "name", "query", "key"].lazy.compactMap { options[$0]?.string }.first ?? words.text() ?? ""
        let line = subject.isEmpty ? verb : "\(verb) “\(subject)”"
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }

    struct Step {
        let statement: String
        let actions: [JSONValue]
        let error: String?
        let result: JSONValue?
    }

    /// Each statement with what the `dash` result says about it.
    private func steps(_ script: String) -> [Step] {
        let entries: [JSONValue] = resultJSON.map { $0.array ?? [$0] } ?? []
        return DashScript.statements(script).enumerated().map { index, statement in
            let entry: JSONValue? = entries.indices.contains(index) ? entries[index] : nil
            return Step(statement: statement, actions: entry?["actions"]?.array ?? [], error: entry?["error"]?.string, result: entry?["result"])
        }
    }
}

private struct StepRow: View {
    let step: ToolCallView.Step
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(step.actions.enumerated()), id: \.offset) { _, action in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(action["tool"]?.string ?? "tool", systemImage: action["asks_first"]?.bool == true ? "hand.raised" : "wrench.and.screwdriver")
                            .font(.caption.bold())
                        if let fields = action["input"]?.object, !fields.isEmpty { FieldsView(fields: fields) }
                    }
                }
                if let error = step.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else if let result = step.result {
                    ResultText(text: result.string ?? result.jsonString(pretty: true), isError: false)
                }
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: step.error != nil ? "xmark.circle" : step.result != nil || !step.actions.isEmpty ? "checkmark.circle" : "circle.dotted")
                    .foregroundStyle(step.error != nil ? .red : .green)
                    .font(.caption)
                Text(ToolCallView.headline(step.statement)).font(.caption.monospaced()).lineLimit(1)
            }
        }
    }
}

/// Input fields: a label, then the value (long text folded).
struct FieldsView: View {
    let fields: [String: JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields.sorted { $0.key < $1.key }, id: \.key) { field in
                VStack(alignment: .leading, spacing: 1) {
                    Text(field.key).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(field.value.string ?? field.value.jsonString())
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 6))
    }
}

private struct ResultText: View {
    let text: String
    let isError: Bool
    @State private var all = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text.count > 4000 ? String(text.prefix(4000)) + "…" : text)
                .font(.caption.monospaced())
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(all ? nil : 6)
                .textSelection(.enabled)
            if text.split(separator: "\n").count > 6 || text.count > 500 {
                Button(all ? "Show less" : "Show all") { all.toggle() }.buttonStyle(.link).font(.caption2)
            }
        }
    }
}
