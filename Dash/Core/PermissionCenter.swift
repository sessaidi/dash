import DashKit
import DashKitUI
import AppKit
import Observation
import SwiftData
import SwiftUI

/// A question the user answered "Always Allow": the same request (same key, e.g. the same tool for
/// Dashii) no longer asks. Listed and revocable in Settings › Dashii.
@Model
final class PermissionGrant {
    @Attribute(.unique) var key: String
    /// What was allowed, as the prompt said it ("Dashii wants to run notes_create").
    var label: String
    var grantedAt: Date

    init(key: String, label: String) {
        self.key = key
        self.label = label
        grantedAt = .now
    }
}

/// One place for every "may Dash do this?" question: Claude tool calls that write,
/// agent tool calls outside the pre-approved list, extension permissions and
/// macOS privacy permissions. Requests queue and show one at a time as a modal sheet.
@MainActor
@Observable
final class PermissionCenter: PermissionAsking {
    typealias Detail = PermissionDetail

    struct Request: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let message: String
        let details: [Detail]
        let allowLabel: String
        let denyLabel: String
        let input: JSONValue?
        let remember: String?
        fileprivate let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var current: Request?
    @ObservationIgnored private var queue: [Request] = []
    /// Where "Always Allow" answers are kept (Dash's database); nil keeps nothing.
    @ObservationIgnored var store: ModelContext?

    /// The key to remember a tool's approval under, or nil for tools that must always ask
    /// (deleting, executing, pruning: one "always" there costs too much).
    static func rememberKey(_ scope: String, tool: DashiiTool) -> String? {
        let risky = ["delete", "remove", "prune", "exec", "drop", "destroy", "kill", "reset", "force"]
        guard !tool.writesRemotely, !risky.contains(where: { tool.name.localizedCaseInsensitiveContains($0) }) else { return nil }
        return "\(scope):tool:\(tool.name)"
    }

    func isGranted(_ key: String) -> Bool {
        guard let store else { return false }
        return ((try? store.fetchCount(FetchDescriptor<PermissionGrant>(predicate: #Predicate { $0.key == key }))) ?? 0) > 0
    }

    /// Shows the modal and waits for the answer. Returns true when allowed (or always allowed).
    func ask(_ prompt: PermissionPrompt) async -> Bool {
        if let key = prompt.remember, isGranted(key) { return true }
        return await withCheckedContinuation { continuation in
            let request = Request(icon: prompt.icon, title: prompt.title, message: prompt.message, details: prompt.details,
                                  allowLabel: prompt.allowLabel, denyLabel: prompt.denyLabel, input: prompt.input,
                                  remember: prompt.remember, continuation: continuation)
            if current == nil {
                current = request
                NSApp.activate()
            } else {
                queue.append(request)
            }
        }
    }

    /// `always` keeps the answer for requests with the same key, and answers the queued ones too.
    func resolve(_ allowed: Bool, always: Bool = false) {
        guard let request = current else { return }
        if always, allowed, let key = request.remember, let store {
            if !isGranted(key) { store.insert(PermissionGrant(key: key, label: request.title)) }
            try? store.save()
        }
        current = queue.isEmpty ? nil : queue.removeFirst()
        request.continuation.resume(returning: allowed)
        if let next = current, let key = next.remember, isGranted(key) { resolve(true) }
    }

    /// Denies everything waiting (used when a run is stopped).
    func denyAll() {
        while current != nil { resolve(false) }
    }
}

struct PermissionSheet: View {
    let request: PermissionCenter.Request
    @Environment(PermissionCenter.self) private var center

    var body: some View {
        // The buttons stay on screen whatever the prompt's length: the text scrolls instead.
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }.frame(height: 460)
            }
            .frame(maxHeight: 460)
            buttons
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title).font(.headline)
                    Text(request.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let input = request.input, case .object(let fields) = input, !fields.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(fields.sorted { $0.key < $1.key }, id: \.key) { field in
                        InputField(name: field.key, value: field.value)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            }
            ForEach(request.details, id: \.self) { detail in
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.title).font(.callout.bold())
                    Text(detail.text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(12)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            if request.remember != nil {
                Button("Always Allow") { center.resolve(true, always: true) }
                    .help("Don't ask again for this. Revoke it in Settings › Dashii.")
            }
            Spacer()
            Button(request.denyLabel) { center.resolve(false) }
                .keyboardShortcut(.cancelAction)
            Button(request.allowLabel) { center.resolve(true) }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// One input field, readable: a label, then the value (long text folded, lists inline).
private struct InputField: View {
    let name: String
    let value: JSONValue
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch value {
            case .string(let text):
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(text.contains("\n") ? .callout : .body)
                    .lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled)
                if text.count > 240 || text.split(separator: "\n").count > 4 {
                    Button(expanded ? "Show less" : "Show all \(text.split(separator: "\n").count) lines") { expanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            case .array(let items) where items.allSatisfy({ $0.string != nil || $0.double != nil }):
                Text(items.map { $0.string ?? $0.jsonString() }.joined(separator: ", ")).textSelection(.enabled)
            case .bool(let flag):
                Text(flag ? "Yes" : "No")
            case .number, .null:
                Text(value.jsonString()).monospacedDigit()
            default:
                Text(value.jsonString(pretty: true)).font(.caption.monospaced()).lineLimit(expanded ? nil : 6).textSelection(.enabled)
            }
        }
    }

    /// "noteTitle" and "note_title" read as "Note title".
    private var label: String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
            .replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2.lowercased())" }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

extension View {
    /// Presents the permission center's requests as a modal sheet on this window.
    func permissionModal(_ center: PermissionCenter) -> some View {
        sheet(item: Binding(get: { center.current }, set: { if $0 == nil { center.resolve(false) } })) { request in
            PermissionSheet(request: request).environment(center)
        }
    }
}
