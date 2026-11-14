import SwiftUI

/// Empty, loading, error and "connect first" states every widget needs, in one place.
public enum ContentState {
    case loading(String = "Loading…")
    case empty(title: String, systemImage: String, message: String? = nil)
    case failed(title: String = "Couldn't load", message: String)
    /// A feature whose integrations aren't connected.
    case needsConnection(names: [String])
}

public struct StateView: View {
    let state: ContentState
    let action: (title: String, run: () -> Void)?

    /// `action` adds a button: Retry, Open Settings, Connect…
    public init(_ state: ContentState, action: (title: String, run: () -> Void)? = nil) {
        self.state = state
        self.action = action
    }

    public var body: some View {
        switch state {
        case .loading(let title):
            VStack(spacing: 8) {
                ProgressView()
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty(let title, let systemImage, let message):
            unavailable(title: title, systemImage: systemImage, message: message)
        case .failed(let title, let message):
            unavailable(title: title, systemImage: "exclamationmark.triangle", message: message)
        case .needsConnection(let names):
            unavailable(
                title: "Connect \(ListFormatter.localizedString(byJoining: names))", systemImage: "link",
                message: names.count == 1 ? "This feature needs that integration." : "This feature needs these integrations.")
        }
    }

    private func unavailable(title: String, systemImage: String, message: String?) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let action { Button(action.title, action: action.run) }
        }
    }
}

#Preview("States") {
    HStack {
        StateView(.loading())
        StateView(.empty(title: "No open PRs", systemImage: "checkmark.circle"))
        StateView(.failed(message: "Can't reach the cluster."), action: ("Retry", {}))
        StateView(.needsConnection(names: ["GitHub", "Atlassian"]), action: ("Open Extensions", {}))
    }
    .frame(width: 1000, height: 240)
}
