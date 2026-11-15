import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Launch progress shown on the splash screen.
@MainActor
@Observable
final class BootState {
    struct Step: Identifiable {
        enum Status: Equatable { case pending, running, done, warning(String), skipped }
        let id: String
        let title: String
        let systemImage: String
        var status: Status = .pending
    }

    private(set) var steps: [Step] = []
    /// The user skipped or everything finished: show the dashboard.
    private(set) var finished = false

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(steps.filter { $0.status != .pending && $0.status != .running }.count) / Double(steps.count)
    }

    var current: String {
        steps.first { $0.status == .running }?.title ?? (finished ? "Ready" : "Starting…")
    }

    func add(_ id: String, _ title: String, systemImage: String) {
        steps.append(Step(id: id, title: title, systemImage: systemImage))
    }

    func set(_ id: String, _ status: Step.Status) {
        if let index = steps.firstIndex(where: { $0.id == id }) { steps[index].status = status }
    }

    func finish() { finished = true }
}

extension ExtensionHost {
    /// Launch: start every extension, connect integrations and do the
    /// first sync of each feature, reporting each step to `state`. Integrations run in parallel,
    /// then features in parallel; each step has a timeout so one slow service can't hold launch.
    func boot(_ state: BootState) async {
        state.add("store", "Opening the database", systemImage: "cylinder")
        state.add("plugins", "Loading plugins", systemImage: "shippingbox")
        state.add("extensions", "Starting extensions", systemImage: "puzzlepiece.extension")
        state.set("store", .done)
        let failedPlugins = plugins.filter { if case .failed = $0.state { return true }; return false }
        state.set("plugins", failedPlugins.isEmpty ? .done : .warning("\(failedPlugins.count) failed"))

        state.set("extensions", .running)
        start()
        state.set("extensions", extensionErrors.isEmpty ? .done : .warning("\(extensionErrors.count) problems"))
        // From now on, plugins dropped into the Plugins folder load without a relaunch.
        if !inMemory {
            HotPlugins.shared.start(host: self)
            HookEngine.shared.start(host: self)
            AgentHub.shared.start(host: self)
        }

        let integrations = extensions.filter { $0.layer == .integration && isEnabled($0) }
        let features = extensions.filter { $0.layer == .feature && isEnabled($0) }
        for item in integrations { state.add(item.id, "Connecting \(item.name)", systemImage: item.systemImage) }
        for item in features { state.add(item.id, "Loading \(item.name)", systemImage: item.systemImage) }
        state.add("dashboard", "Preparing the dashboard", systemImage: "square.grid.2x2")

        await prepareAll(integrations, timeout: .seconds(12), state: state)
        await prepareAll(features, timeout: .seconds(25), state: state)

        state.set("dashboard", .done)
        DashLog.notice("Launch finished: \(state.steps.filter { if case .warning = $0.status { return true }; return false }.count) warnings", category: "boot")
        state.finish()
    }

    private func prepareAll(_ items: [any DashExtension], timeout: Duration, state: BootState) async {
        let tasks = items.map { item in
            Task { @MainActor in await self.prepareOne(item, timeout: timeout, state: state) }
        }
        for task in tasks { await task.value }
    }

    struct TimeoutError: Error {}

    @MainActor private final class Once {
        var done = false
    }

    /// Awaits `item.prepare`, giving up after `timeout` (the work keeps running in the background).
    private func prepareOne(_ item: any DashExtension, timeout: Duration, state: BootState) async {
        state.set(item.id, .running)
        let once = Once()
        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            Task { @MainActor in
                let result: Result<Void, Error>
                do { try await item.prepare(host: self); result = .success(()) } catch { result = .failure(error) }
                if !once.done { once.done = true; continuation.resume(returning: result) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !once.done { once.done = true; continuation.resume(returning: .failure(TimeoutError())) }
            }
        }
        switch outcome {
        case .success:
            state.set(item.id, .done)
        case .failure(let error):
            let message = error is TimeoutError ? "timed out" : error.localizedDescription
            DashLog.error("\(item.id) didn't finish preparing: \(message)", category: "boot")
            state.set(item.id, .warning(message))
        }
    }
}

/// The launch screen: overall progress and each step's status.
struct SplashView: View {
    let state: BootState
    @State private var canSkip = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Dash").font(.largeTitle.bold())
            VStack(spacing: 6) {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 360)
                    .animation(.easeOut, value: state.progress)
                Text(state.current).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.steps) { step in
                        HStack(spacing: 8) {
                            icon(step.status).frame(width: 18)
                            Image(systemName: step.systemImage).foregroundStyle(.secondary).frame(width: 18)
                            Text(step.title).font(.callout)
                            Spacer()
                            if case .warning(let message) = step.status {
                                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(width: 420)
            }
            .frame(maxHeight: 300)
            Button("Skip") { state.finish() }
                .opacity(canSkip ? 1 : 0)
                .disabled(!canSkip)
                .help("Open the dashboard now; loading continues in the background")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task {
            try? await Task.sleep(for: .seconds(3))
            canSkip = true
        }
    }

    @ViewBuilder
    private func icon(_ status: BootState.Step.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
