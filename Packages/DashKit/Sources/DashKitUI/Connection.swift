import SwiftUI

/// Where an integration's account stands.
public enum ConnectionState: Equatable, Sendable {
    case notConfigured
    case checking
    /// Connected; the detail is usually "Signed in as …".
    case connected(String?)
    case failed(String)

    public var tone: Tone {
        switch self {
        case .notConfigured: .neutral
        case .checking: .info
        case .connected: .success
        case .failed: .danger
        }
    }

    public var title: String {
        switch self {
        case .notConfigured: "Not connected"
        case .checking: "Checking…"
        case .connected(let detail): detail ?? "Connected"
        case .failed(let message): message
        }
    }

    public var isConnected: Bool { if case .connected = self { return true }; return false }
}

/// One-line status for an integration: icon + text in the state's tone.
public struct ConnectionStatusLabel: View {
    let state: ConnectionState

    public init(_ state: ConnectionState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .checking: ProgressView().controlSize(.small)
            case .notConfigured: Image(systemName: "circle.dashed")
            case .connected: Image(systemName: "checkmark.circle.fill")
            case .failed: Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(state.title).lineLimit(3).textSelection(.enabled)
        }
        .foregroundStyle(state.tone.color)
    }
}

/// A secret input that never shows the stored value: type a new one, Save, or Remove.
public struct SecretField: View {
    /// What a filled field shows; the host sets it to match where secrets are kept.
    nonisolated(unsafe) public static var savedLabel = "Saved"

    let title: String
    let placeholder: String
    let isStored: Bool
    let onSave: (String) -> Void
    let onRemove: (() -> Void)?
    @State private var text = ""

    public init(_ title: String, placeholder: String = "", isStored: Bool, onSave: @escaping (String) -> Void, onRemove: (() -> Void)? = nil) {
        self.title = title
        self.placeholder = placeholder
        self.isStored = isStored
        self.onSave = onSave
        self.onRemove = onRemove
    }

    public var body: some View {
        LabeledContent(title) {
            HStack {
                SecureField(title, text: $text, prompt: Text(isStored ? Self.savedLabel : placeholder))
                    .labelsHidden()
                    .onSubmit(save)
                Button("Save", action: save).disabled(text.isEmpty)
                if isStored, let onRemove {
                    Button("Remove", role: .destructive, action: onRemove)
                }
            }
        }
    }

    private func save() {
        guard !text.isEmpty else { return }
        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = ""
    }
}

#Preview("Connection") {
    Form {
        ConnectionStatusLabel(.notConfigured)
        ConnectionStatusLabel(.checking)
        ConnectionStatusLabel(.connected("Signed in as octocat"))
        ConnectionStatusLabel(.failed("GitHub rejected the credentials (401)."))
        SecretField("Token", placeholder: "ghp_…", isStored: true, onSave: { _ in }, onRemove: {})
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
