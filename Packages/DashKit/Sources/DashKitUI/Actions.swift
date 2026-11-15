import SwiftUI

/// A button that runs async work, shows a spinner while it runs, and reports failures.
public struct AsyncButton<Label: View>: View {
    let role: ButtonRole?
    let action: () async throws -> Void
    let onError: (Error) -> Void
    let label: Label
    @State private var running = false

    public init(
        role: ButtonRole? = nil, action: @escaping () async throws -> Void, onError: @escaping (Error) -> Void = { _ in },
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.action = action
        self.onError = onError
        self.label = label()
    }

    public var body: some View {
        Button(role: role) {
            running = true
            Task {
                do { try await action() } catch { onError(error) }
                running = false
            }
        } label: {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.small) }
                label
            }
        }
        .disabled(running)
    }
}

extension AsyncButton where Label == Text {
    public init(_ title: String, role: ButtonRole? = nil, action: @escaping () async throws -> Void, onError: @escaping (Error) -> Void = { _ in }) {
        self.init(role: role, action: action, onError: onError) { Text(title) }
    }
}

/// Header, scrolling content, error line and a footer of actions: the shape of every detail sheet.
public struct DetailScaffold<Badges: View, Content: View, Actions: View>: View {
    let title: String
    let subtitle: String?
    let error: String?
    let badges: Badges
    let content: Content
    let actions: Actions
    @Environment(\.dismiss) private var dismiss

    public init(
        _ title: String, subtitle: String? = nil, error: String? = nil,
        @ViewBuilder badges: () -> Badges = { EmptyView() },
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.error = error
        self.badges = badges()
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.bold()).lineLimit(2)
                badges
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            HStack { actions }
        }
        .padding(20)
    }
}

/// A titled group inside a detail view.
public struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

#Preview("Detail") {
    DetailScaffold("acme/api#812", subtitle: "jrivera wants to merge retry into main", error: "Merge blocked by branch protection.", badges: {
        Badge("high risk", tone: .danger)
    }, content: {
        DetailSection("Summary") { Text("Adds retries with backoff; POST isn't idempotent.") }
    }, actions: {
        AsyncButton("Re-review") { try await Task.sleep(for: .seconds(1)) }
        Spacer()
        Button("Merge…") {}
    })
    .frame(width: 560, height: 360)
}
