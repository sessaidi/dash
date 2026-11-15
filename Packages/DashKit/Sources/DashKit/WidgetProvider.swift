import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Where a widget's data comes from, apart from how it looks: given the widget's configuration,
/// one `Snapshot` (plain, `Sendable` data). `ProvidedWidget` runs it: first load, refreshes while
/// the widget is on screen, loading, failure and stale states, retry.
///
///     struct TicketsProvider: WidgetDataProvider {
///         let host: any ExtensionContext
///         var refresh: WidgetRefresh { .every(.seconds(120)) }
///         func snapshot(for config: TicketsConfig) async throws -> TicketsSnapshot { … }
///     }
///
///     static func content(config: Binding<TicketsConfig>, context: WidgetContext) -> some View {
///         ProvidedWidget(TicketsProvider(host: context.host), config: config.wrappedValue) { snapshot, layout in
///             TicketsView(snapshot: snapshot, layout: layout)
///         }
///     }
///
/// Keep views free of fetching: they render a snapshot, so they preview with sample data.
@MainActor
public protocol WidgetDataProvider {
    associatedtype Config: Equatable & Sendable
    associatedtype Snapshot: Sendable

    /// How often the host reloads while the widget is visible.
    var refresh: WidgetRefresh { get }
    func snapshot(for config: Config) async throws -> Snapshot
}

public enum WidgetRefresh: Sendable, Equatable {
    /// Loaded when shown and when the configuration changes; Retry reloads.
    case manual
    case every(Duration)

    var interval: Duration? {
        if case .every(let interval) = self { return interval }
        return nil
    }
}

/// Runs a provider: the latest snapshot, when it was taken, the last error, and a refresh loop.
/// A failed reload keeps the previous snapshot (shown as stale) instead of blanking the widget.
@MainActor
@Observable
public final class WidgetSnapshotLoader<Provider: WidgetDataProvider> {
    public private(set) var snapshot: Provider.Snapshot?
    public private(set) var updatedAt: Date?
    public private(set) var error: String?
    public private(set) var isLoading = false

    @ObservationIgnored let provider: Provider
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(provider: Provider) {
        self.provider = provider
    }

    /// The snapshot is older than two refresh intervals, or the last reload failed.
    public func isStale(now: Date = .now) -> Bool {
        guard snapshot != nil else { return false }
        if error != nil { return true }
        guard let interval = provider.refresh.interval, let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > 2 * Double(interval.components.seconds)
    }

    /// Loads once. A load started later wins over one still running.
    public func load(_ config: Provider.Config) async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let snapshot = try await provider.snapshot(for: config)
            guard mine == generation, !Task.isCancelled else { return }
            self.snapshot = snapshot
            updatedAt = .now
            error = nil
        } catch is CancellationError {
        } catch {
            guard mine == generation else { return }
            self.error = (error as? ToolError)?.message ?? error.localizedDescription
        }
    }

    /// Loads now, then on the provider's interval until `stop`.
    public func start(_ config: Provider.Config) {
        loop?.cancel()
        let interval = provider.refresh.interval
        loop = Task { [weak self] in
            await self?.load(config)
            guard let interval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.load(config)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}

/// A widget body backed by a `WidgetDataProvider`: loads while it's on screen and the app is
/// active, pauses otherwise, and shows the host's loading, failure and stale states.
public struct ProvidedWidget<Provider: WidgetDataProvider, Content: View>: View {
    @State private var loader: WidgetSnapshotLoader<Provider>
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    let config: Provider.Config
    let loadingTitle: String
    let content: (Provider.Snapshot, WidgetLayout) -> Content

    /// `content` gets the snapshot and the room it has (`layout.family`: narrow, medium, wide,
    /// large): give each family its own layout rather than stretching one.
    public init(_ provider: @autoclosure () -> Provider, config: Provider.Config, loading: String = "Loading…",
                @ViewBuilder content: @escaping (Provider.Snapshot, WidgetLayout) -> Content) {
        _loader = State(initialValue: WidgetSnapshotLoader(provider: provider()))
        self.config = config
        loadingTitle = loading
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                if let snapshot = loader.snapshot {
                    content(snapshot, WidgetLayout(size: geometry.size))
                        .overlay(alignment: .topTrailing) { staleBadge }
                } else if let error = loader.error {
                    StateView(.failed(message: error), action: ("Retry", { Task { await loader.load(config) } }))
                } else {
                    StateView(.loading(loadingTitle))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { visible = true; resume() }
        .onDisappear { visible = false; loader.stop() }
        .onChange(of: config) { resume() }
        .onChange(of: scenePhase) { resume() }
    }

    private func resume() {
        if visible, scenePhase != .background { loader.start(config) } else { loader.stop() }
    }

    @ViewBuilder private var staleBadge: some View {
        if loader.isStale() {
            Image(systemName: loader.error == nil ? "clock.badge.exclamationmark" : "exclamationmark.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(4)
                .help(loader.error.map { "Showing older data: \($0)" } ?? "Showing older data")
                .onTapGesture { Task { await loader.load(config) } }
        }
    }
}
