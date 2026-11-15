import DashKit
import DashKitUI
import AppKit
import Observation
import SwiftUI

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
        fileprivate let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var current: Request?
    @ObservationIgnored private var queue: [Request] = []

    /// Shows the modal and waits for the answer. Returns true when allowed.
    func ask(_ prompt: PermissionPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = Request(icon: prompt.icon, title: prompt.title, message: prompt.message, details: prompt.details,
                                  allowLabel: prompt.allowLabel, denyLabel: prompt.denyLabel, continuation: continuation)
            if current == nil {
                current = request
                NSApp.activate()
            } else {
                queue.append(request)
            }
        }
    }

    func resolve(_ allowed: Bool) {
        guard let request = current else { return }
        current = queue.isEmpty ? nil : queue.removeFirst()
        request.continuation.resume(returning: allowed)
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
            if !request.details.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(request.details, id: \.self) { detail in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(detail.title).font(.callout.bold())
                                Text(detail.text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            }
    }

    private var buttons: some View {
            HStack {
                Spacer()
                Button(request.denyLabel) { center.resolve(false) }
                    .keyboardShortcut(.cancelAction)
                Button(request.allowLabel) { center.resolve(true) }
                    .keyboardShortcut(.defaultAction)
            }
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
