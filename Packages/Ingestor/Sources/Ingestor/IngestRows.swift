import DashKit
import Foundation
import Observation
import SwiftData

/// Rows of an integration's table for a view: read from its database (your own, or the one of
/// the integration you depend on, opened with `IngestDatabase.reading`), read again whenever one
/// of `fetchers` stores, and fetched through the integration when nothing matches or the newest
/// row is older than `maxAge`.
///
///     @State private var runs: IngestRows<GitHubRun>
///     init(database: IngestDatabase, host: any ExtensionContext, repo: String, branch: String) {
///         let descriptor = FetchDescriptor<GitHubRun>(predicate: #Predicate { $0.repo == repo && $0.branch == branch })
///         _runs = State(initialValue: IngestRows(database, descriptor, host: host, fetcher: "github.workflow_runs",
///                                                input: ["repo": .string(repo), "branch": .string(branch)]))
///     }
@MainActor
@Observable
public final class IngestRows<Row: IngestRow> {
    public private(set) var rows: [Row] = []
    public private(set) var isFetching = false
    /// The last fetch failure (the rows read stay shown).
    public private(set) var error: String?
    /// The newest row's fetch time.
    public var syncedAt: Date? { rows.map(\.syncedAt).max() }
    public var clock: @MainActor () -> Date = { .now }

    @ObservationIgnored public let database: IngestDatabase
    @ObservationIgnored let descriptor: FetchDescriptor<Row>
    @ObservationIgnored let fetcher: String?
    @ObservationIgnored let input: JSONValue
    @ObservationIgnored let maxAge: Duration
    @ObservationIgnored private weak var host: (any ExtensionContext)?
    @ObservationIgnored nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    /// `fetcher` and `input`: what to fetch when nothing matches or it's stale (nil: never fetch).
    /// `fetchers`: whose stores also change these rows (the fetcher always does).
    public init(_ database: IngestDatabase, _ descriptor: FetchDescriptor<Row>, host: (any ExtensionContext)?, fetcher: String? = nil,
                input: JSONValue = [:], maxAge: Duration = .seconds(600), fetchers: Set<String> = []) {
        self.database = database
        self.descriptor = descriptor
        self.host = host
        self.fetcher = fetcher
        self.input = input
        self.maxAge = maxAge
        let heard = fetchers.union(fetcher.map { [$0] } ?? [])
        observer = NotificationCenter.default.addObserver(forName: IngestNotification.name, object: nil, queue: .main) { [weak self] note in
            guard let fetcher = note.userInfo?["fetcher"] as? String, heard.contains(fetcher) else { return }
            MainActor.assumeIsolated { self?.read() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Older than `maxAge`, or nothing read.
    public var stale: Bool { Freshness(syncedAt: syncedAt, maxAge: maxAge, refresh: nil, now: clock()).stale }

    /// Reads the rows, then fetches when nothing matches or they're stale.
    public func load() async {
        read()
        if fetcher != nil, rows.isEmpty || stale { await refresh() }
    }

    /// Asks the integration to fetch now, then reads.
    public func refresh() async {
        guard let host, let fetcher else { return }
        isFetching = true
        error = await IngestFetches.run(host, fetcher, input)
        isFetching = false
        read()
    }

    public func read() {
        rows = (try? database.context.fetch(descriptor)) ?? []
    }
}
