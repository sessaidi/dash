import DashKit
import Foundation
import Observation
import SwiftUI

/// Something an integration keeps fetched on a cycle: `fetcher` for each of `inputs()` (one per
/// watched repository, project…), every few minutes.
@MainActor
public struct IngestSyncItem: Identifiable {
    public let id: String
    /// "Open pull requests".
    public let title: String
    /// "Of each watched repository."
    public let detail: String
    public let fetcher: String
    public let inputs: @MainActor () -> [JSONValue]
    public let defaultMinutes: Int
    public let defaultOn: Bool

    public init(id: String, title: String, detail: String = "", fetcher: String, defaultMinutes: Int = 10, defaultOn: Bool = true,
                inputs: @escaping @MainActor () -> [JSONValue] = { [[:]] }) {
        self.id = id
        self.title = title
        self.detail = detail
        self.fetcher = fetcher
        self.defaultMinutes = defaultMinutes
        self.defaultOn = defaultOn
        self.inputs = inputs
    }
}

/// What an integration fetches in the background and how often, set in its settings
/// (`IngestScheduleSection`). While Dash runs, every item that's on is fetched through the
/// integration's fetchers when its interval has passed, so widgets, Dashii and agents find it
/// stored. The choices and the last run of each item are kept in `defaults` under
/// "<prefix>.sync.…", so a restart doesn't fetch everything again.
///
///     schedule = IngestSchedule(prefix: "github", defaults: defaults)
///     schedule.items = [IngestSyncItem(id: "pulls", title: "Open pull requests", fetcher: "github.pulls", defaultMinutes: 5) { … }]
///     schedule.blocked = { [weak self] in self?.hasToken == true ? nil : "Add a token first." }
///     // start(host:): schedule.start(host: host)   stop(): schedule.stop()
@MainActor
@Observable
public final class IngestSchedule {
    public struct Status: Equatable, Sendable {
        public var lastRun: Date?
        /// Inputs fetched at the last run.
        public var fetched = 0
        /// The first failure of the last run, or why it didn't run.
        public var error: String?
        public var isRunning = false
    }

    /// The intervals offered, in minutes.
    public static let choices = [1, 2, 5, 10, 15, 30, 60, 120, 240, 720, 1440]

    public var items: [IngestSyncItem] = []
    /// Background fetching at all. Off: only views and Dashii fetch, when they need to.
    public var isOn: Bool { didSet { defaults.set(isOn, forKey: key("on")) } }
    public private(set) var status: [String: Status] = [:]
    /// Why nothing can be fetched now ("Add a token first.", a used-up rate limit), or nil.
    @ObservationIgnored public var blocked: @MainActor () -> String? = { nil }
    @ObservationIgnored public var clock: @MainActor () -> Date = { .now }
    /// How often the loop looks for due items.
    @ObservationIgnored public var tick: Duration = .seconds(30)

    @ObservationIgnored private let prefix: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var host: (any ExtensionContext)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Bumped by `set`, so the settings view re-reads choices kept in `defaults`.
    private var revision = 0

    public init(prefix: String, defaults: UserDefaults = DashStorage.defaults) {
        self.prefix = prefix
        self.defaults = defaults
        isOn = defaults.object(forKey: prefix + ".sync.on") as? Bool ?? true
    }

    private func key(_ name: String) -> String { prefix + ".sync." + name }

    // MARK: Choices

    public func isOn(_ item: IngestSyncItem) -> Bool {
        _ = revision
        return defaults.object(forKey: key(item.id + ".on")) as? Bool ?? item.defaultOn
    }

    public func minutes(_ item: IngestSyncItem) -> Int {
        _ = revision
        return max(1, defaults.object(forKey: key(item.id + ".minutes")) as? Int ?? item.defaultMinutes)
    }

    public func set(_ item: IngestSyncItem, on: Bool) {
        defaults.set(on, forKey: key(item.id + ".on"))
        revision += 1
    }

    public func set(_ item: IngestSyncItem, minutes: Int) {
        defaults.set(max(1, minutes), forKey: key(item.id + ".minutes"))
        revision += 1
    }

    /// When the item last ran (kept across restarts).
    public func lastRun(_ item: IngestSyncItem) -> Date? {
        status[item.id]?.lastRun ?? (defaults.object(forKey: key(item.id + ".last")) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// When it runs next; nil while it's off.
    public func nextRun(_ item: IngestSyncItem) -> Date? {
        guard isOn, isOn(item) else { return nil }
        return lastRun(item).map { $0.addingTimeInterval(Double(minutes(item)) * 60) } ?? clock()
    }

    /// The items whose interval has passed.
    public var due: [IngestSyncItem] {
        let now = clock()
        return items.filter { item in nextRun(item).map { $0 <= now } ?? false }
    }

    // MARK: Running

    /// Looks for due items now and every `tick` until `stop`.
    public func start(host: any ExtensionContext) {
        self.host = host
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDue()
                guard let tick = self?.tick else { return }
                try? await Task.sleep(for: tick)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Fetches the items that are due.
    public func runDue() async {
        for item in due { await run(item) }
    }

    /// Fetches one item now (or every item that's on), whatever its interval.
    public func runNow(_ id: String? = nil) async {
        for item in items where id == nil ? isOn(item) : item.id == id { await run(item) }
    }

    public var isRunning: Bool { status.values.contains { $0.isRunning } }

    private func run(_ item: IngestSyncItem) async {
        guard let host, status[item.id]?.isRunning != true else { return }
        var current = status[item.id] ?? Status()
        if let reason = blocked() {
            current.error = reason
            status[item.id] = current
            return
        }
        current.isRunning = true
        status[item.id] = current
        var fetched = 0
        var failure: String?
        for input in item.inputs() {
            // Shared with views asking for the same thing at the same time.
            if let error = await IngestFetches.run(host, item.fetcher, input) {
                failure = failure ?? error
                // A used-up rate limit stops this run; the next tick says why.
                if blocked() != nil { break }
            } else {
                fetched += 1
            }
        }
        let now = clock()
        status[item.id] = Status(lastRun: now, fetched: fetched, error: failure)
        defaults.set(now.timeIntervalSince1970, forKey: key(item.id + ".last"))
    }
}

/// The schedule in an integration's settings: background fetching on or off, and for each item
/// a switch, how often, when it last ran (or what failed) and a button to fetch it now.
public struct IngestScheduleSection: View {
    @Bindable var schedule: IngestSchedule
    let footer: String

    public init(_ schedule: IngestSchedule, footer: String = "") {
        self.schedule = schedule
        self.footer = footer
    }

    public var body: some View {
        Section {
            Toggle("Fetch in the background", isOn: $schedule.isOn)
            ForEach(schedule.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(isOn: Binding(get: { schedule.isOn(item) }, set: { schedule.set(item, on: $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        Picker("Every", selection: Binding(get: { schedule.minutes(item) }, set: { schedule.set(item, minutes: $0) })) {
                            ForEach(Self.choices(including: schedule.minutes(item)), id: \.self) { Text(Self.every($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!schedule.isOn(item))
                        Button("Fetch Now", systemImage: "arrow.clockwise") { Task { await schedule.runNow(item.id) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(schedule.status[item.id]?.isRunning == true)
                    }
                    IngestScheduleStatus(schedule: schedule, item: item)
                }
                .disabled(!schedule.isOn)
            }
        } header: {
            HStack {
                Text("Background fetching")
                Spacer()
                if schedule.isRunning { ProgressView().controlSize(.small) }
                Button("Fetch All Now") { Task { await schedule.runNow() } }
                    .buttonStyle(.borderless).font(.callout)
                    .disabled(schedule.isRunning || !schedule.isOn)
            }
        } footer: {
            if !footer.isEmpty { Text(footer) }
        }
    }

    static func choices(including minutes: Int) -> [Int] {
        IngestSchedule.choices.contains(minutes) ? IngestSchedule.choices : (IngestSchedule.choices + [minutes]).sorted()
    }

    /// "Every 5 min", "Every hour", "Every 12 hours", "Every day".
    static func every(_ minutes: Int) -> String {
        switch minutes {
        case 1440: "Every day"
        case 60: "Every hour"
        case let m where m % 60 == 0: "Every \(m / 60) hours"
        default: "Every \(minutes) min"
        }
    }
}

/// "Fetched 3 min ago (4) · next in 2 min", "Fetching…", or what failed.
struct IngestScheduleStatus: View {
    let schedule: IngestSchedule
    let item: IngestSyncItem

    var body: some View {
        let status = schedule.status[item.id]
        HStack(spacing: 4) {
            if status?.isRunning == true {
                ProgressView().controlSize(.mini)
                Text("Fetching…")
            } else if let error = status?.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).lineLimit(1).truncationMode(.tail).help(error)
            } else if let last = schedule.lastRun(item) {
                Text("Fetched \(last.relative)" + (status.map { " (\($0.fetched))" } ?? ""))
            } else {
                Text("Not fetched yet")
            }
            if status?.isRunning != true, schedule.isOn, schedule.isOn(item), let next = schedule.nextRun(item) {
                Text("· next \(next <= schedule.clock() ? "now" : next.relative)").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
