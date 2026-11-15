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
                    let steps = steps(script)
                    if steps.count == 1, let step = steps.first {
                        // One statement: show it like a direct call, no nesting.
                        StepBody(step: step)
                    } else {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                    }
                } else {
                    if let fields = inputJSON?.object, !fields.isEmpty { InputChips(fields: fields) }
                    if let result {
                        if isError { Text(result).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        else if let value = resultJSON { ValueView(value: value) }
                        else { ResultText(text: result, isError: false) }
                    }
                }
                Button(raw ? "Readable view" : "Raw JSON") { raw.toggle() }.buttonStyle(.link).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .padding(.top, 2)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: result == nil ? "hammer" : isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result == nil ? Color.secondary : isError ? .red : .green)
                    .font(.caption)
                Text(summary).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
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
            StepBody(step: step).padding(.leading, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: step.error != nil ? "xmark.circle.fill" : step.result != nil || !step.actions.isEmpty ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(step.error != nil ? .red : .green)
                    .font(.caption2)
                Text(ToolCallView.headline(step.statement)).font(.caption.monospaced()).lineLimit(1)
            }
        }
    }
}

/// What one statement did: the tools it ran with their inputs, then its result or error.
private struct StepBody: View {
    let step: ToolCallView.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(step.actions.enumerated()), id: \.offset) { _, action in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: action["asks_first"]?.bool == true ? "hand.raised" : "wrench.and.screwdriver")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(action["tool"]?.string ?? "tool").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let fields = action["input"]?.object, !fields.isEmpty { InputChips(fields: fields) }
            }
            if let error = step.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if let result = step.result {
                ValueView(value: result)
            }
        }
    }
}

/// Short inputs as chips ("kind howto"); long text goes below, folded.
private struct InputChips: View {
    let fields: [String: JSONValue]

    var body: some View {
        let sorted = fields.sorted { $0.key < $1.key }
        let short = sorted.filter { !Self.isLong($0.value) }
        let long = sorted.filter { Self.isLong($0.value) }
        VStack(alignment: .leading, spacing: 6) {
            if !short.isEmpty {
                FlowChips(items: short.map { ($0.key, $0.value.string ?? $0.value.jsonString()) })
            }
            ForEach(long, id: \.key) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.key).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    FoldedText(text: field.value.string ?? field.value.jsonString(pretty: true), lines: 4)
                }
            }
        }
    }

    static func isLong(_ value: JSONValue) -> Bool {
        if let text = value.string { return text.count > 60 || text.contains("\n") }
        return value.object != nil || (value.array?.count ?? 0) > 3
    }
}

/// key value pairs in rounded chips, wrapping.
private struct FlowChips: View {
    let items: [(String, String)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(items, id: \.0) { key, value in
            HStack(spacing: 4) {
                Text(key).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: .capsule)
        }
    }
}

/// A result, readable: objects as label/value rows, text with its real lines, lists summarised.
struct ValueView: View {
    let value: JSONValue
    var depth = 0

    var body: some View {
        switch value {
        case .object(let fields):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(fields.sorted { $0.key < $1.key }.filter { !$0.value.isNull }, id: \.key) { field in
                    if ValueView.isScalar(field.value) && (field.value.string?.count ?? 0) <= 80 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(field.key).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                            Text(field.value.string ?? field.value.jsonString()).font(.caption).textSelection(.enabled)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.key).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            if depth < 2 { ValueView(value: field.value, depth: depth + 1).padding(.leading, 6) }
                            else { FoldedText(text: field.value.jsonString(pretty: true), lines: 3) }
                        }
                    }
                }
            }
            .padding(depth == 0 ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(depth == 0 ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        case .array(let items):
            if items.isEmpty {
                Text("none").font(.caption).foregroundStyle(.secondary)
            } else if items.allSatisfy(ValueView.isScalar) {
                Text(items.prefix(12).map { $0.string ?? $0.jsonString() }.joined(separator: ", ") + (items.count > 12 ? " … +\(items.count - 12)" : ""))
                    .font(.caption).textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                        Label(ValueView.title(of: item), systemImage: "smallcircle.filled.circle").font(.caption).lineLimit(1)
                    }
                    if items.count > 6 { Text("+\(items.count - 6) more").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        case .string(let text):
            FoldedText(text: text, lines: 6)
        default:
            Text(value.jsonString()).font(.caption).textSelection(.enabled)
        }
    }

    static func isScalar(_ value: JSONValue) -> Bool { value.object == nil && value.array == nil }

    /// A one-line name for a row: its title, name, key or id, else its first text.
    static func title(of value: JSONValue) -> String {
        guard let object = value.object else { return value.string ?? value.jsonString() }
        for key in ["title", "name", "key", "id", "path", "summary"] { if let text = object[key]?.string { return text } }
        return object.values.compactMap(\.string).first ?? value.jsonString()
    }
}

/// Text with its real line breaks, folded after `lines`.
private struct FoldedText: View {
    let text: String
    let lines: Int
    @State private var all = false

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
        VStack(alignment: .leading, spacing: 2) {
            Text(trimmed.count > 6000 ? String(trimmed.prefix(6000)) + "…" : trimmed)
                .font(.caption)
                .lineLimit(all ? nil : lines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if count > lines || trimmed.count > lines * 90 {
                Button(all ? "Show less" : "Show all \(count) lines") { all.toggle() }.buttonStyle(.link).font(.caption2)
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
