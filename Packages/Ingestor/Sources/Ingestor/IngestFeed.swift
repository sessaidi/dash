import DashKit
import Foundation
import Observation
import SwiftUI

/// What a widget shows from Dash's database: the stored answer of a resource (through its reader,
/// so it works for any integration's data), refreshed in the background through its fetcher when
/// it's missing or stale, and re-read whenever that fetcher stores again.
///
///     @State private var checks: IngestFeed
///     init(host: any ExtensionContext, repo: String, sha: String) {
///         _checks = State(initialValue: IngestFeed(host: host, fetcher: "github.checks", reader: "github_checks",
///                                                  input: ["repo": .string(repo), "ref": .string(sha)]))
///     }
///     var body: some View { … checks.data … .task { await checks.load() } }
@MainActor
@Observable
public final class IngestFeed {
    public let fetcher: String
    public let reader: String
    public private(set) var input: JSONValue
    /// The stored answer without its freshness fields; nil while nothing is stored.
    public private(set) var data: JSONValue?
    public private(set) var syncedAt: Date?
    /// Older than the integration's window, or never fetched.
    public private(set) var stale = true
    public private(set) var isFetching = false
    /// The last read or fetch failure (the stored copy stays shown).
    public private(set) var error: String?
    /// Fetch when nothing is stored or it's stale (`load`). Off: only `refresh` fetches.
    public var autoFetch: Bool

    @ObservationIgnored private weak var host: (any ExtensionContext)?
    @ObservationIgnored nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    public init(host: any ExtensionContext, fetcher: String, reader: String, input: JSONValue = [:], autoFetch: Bool = true) {
        self.host = host
        self.fetcher = fetcher
        self.reader = reader
        self.input = input
        self.autoFetch = autoFetch
        observer = NotificationCenter.default.addObserver(forName: IngestNotification.name, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["fetcher"] as? String == fetcher else { return }
            MainActor.assumeIsolated { Task { await self?.read() } }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Shows what's stored, then fetches if it's missing or stale (with `autoFetch`).
    public func load() async {
        await read()
        if autoFetch, data == nil || stale { await refresh() }
    }

    /// Asks the integration to fetch now (one request for every feed showing the same thing),
    /// then shows the result.
    public func refresh() async {
        guard let host else { return }
        let key = "\(ObjectIdentifier(host)) \(fetcher) \(input.jsonString())"
        if let running = Self.running[key] {
            await running.value
        } else {
            isFetching = true
            let fetcher = fetcher, input = input
            let task = Task { @MainActor () -> String? in
                do { _ = try await host.fetch(fetcher, input); return nil } catch { return error.localizedDescription }
            }
            Self.running[key] = Task { _ = await task.value }
            error = await task.value
            Self.running[key] = nil
            isFetching = false
        }
        await read()
    }

    /// Re-reads the stored answer.
    public func read() async {
        guard let host else { return }
        let asked = input
        guard let tool = host.extensions.filter({ host.isEnabled($0) }).flatMap(\.tools).first(where: { $0.name == reader }) else {
            error = "Nothing reads “\(reader)”: is its integration turned on?"
            return
        }
        do {
            let answer = try await tool.run(asked)
            // Showing something else since (`show`): this answer is for the old input.
            guard asked == input else { return }
            apply(answer)
        } catch {
            guard asked == input else { return }
            self.error = error.localizedDescription
        }
    }

    /// Shows something else (another pull request…): reads it, fetching when needed.
    public func show(_ input: JSONValue) async {
        guard input != self.input else { return }
        self.input = input
        data = nil
        syncedAt = nil
        stale = true
        await load()
    }

    /// The data decoded, or nil.
    public func decode<T: Decodable>(_ type: T.Type) -> T? { try? data?.decode(type) }

    func apply(_ answer: JSONValue) {
        if answer["fetched"]?.bool == false {
            data = nil
            syncedAt = nil
            stale = true
            return
        }
        data = Ingestor.data(of: answer)
        syncedAt = answer["synced_at"].flatMap { DashDate.parse($0) }
        stale = answer["stale"]?.bool ?? (syncedAt == nil)
    }

    private static var running: [String: Task<Void, Never>] = [:]
}

/// "Synced 5 min ago" (or "Refreshing…", or the error), with a refresh button.
public struct IngestStatus: View {
    let feed: IngestFeed

    public init(_ feed: IngestFeed) { self.feed = feed }

    public var body: some View {
        HStack(spacing: 6) {
            if feed.isFetching {
                ProgressView().controlSize(.mini)
                Text("Refreshing…")
            } else if let error = feed.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).lineLimit(1).truncationMode(.tail).help(error)
            } else if let syncedAt = feed.syncedAt {
                Text("Synced \(syncedAt.relative)").foregroundStyle(feed.stale ? .orange : .secondary)
            } else {
                Text("Not fetched yet")
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await feed.refresh() } }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(feed.isFetching)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
