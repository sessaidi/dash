import DashKit
import Foundation

/// GET requests to one account through its `IntegrationConnection`, for fetchers: pages through
/// lists, sends the last answer's ETag (a 304 returns the stored copy, and GitHub doesn't count
/// it against the rate limit), and stops calling a service that said its rate limit is used up
/// until it resets.
@MainActor
public struct IngestClient {
    public let connection: IntegrationConnection
    /// The service's name in errors ("GitHub").
    public let service: String
    /// Whose requests these are: ETags and rate limits are kept per scope.
    public let scope: String
    /// Where ETags and their answers are kept (kind `ingest.etag`); nil: no conditional requests.
    public let store: (any SyncedStore)?
    public var source: String
    /// Answers bigger than this (bytes) aren't kept for ETags.
    public var etagBodyLimit = 512_000
    /// How long to wait after a rate-limit error that doesn't say until when.
    public var rateLimitPause: TimeInterval = 60
    public var clock: @MainActor () -> Date = { .now }

    public static let etagKind = "ingest.etag"
    /// ETag records kept per scope; the oldest go first.
    public static let etagLimit = 500

    public init(connection: IntegrationConnection, service: String, scope: String, store: (any SyncedStore)? = nil, source: String = "ingestor") {
        self.connection = connection
        self.service = service
        self.scope = scope
        self.store = store
        self.source = source
    }

    /// GET a path on the connection (or a full URL on its hosts) and parse the JSON.
    public func get(_ pathOrURL: String, headers: [String: String] = [:]) async throws -> IngestResponse {
        let url = try resolve(pathOrURL)
        try IngestRateLimit.check(service: service, scope: scope, now: clock())
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let etagKey = JSONValue.string(url.absoluteString).queryKey
        let cached = store?.record(kind: Self.etagKind, scope: scope, key: etagKey)
        if let etag = cached?.value["etag"]?.string { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await connection.send(request, service: service)
        } catch let error as HTTPError where IngestRateLimit.isRateLimit(error) {
            IngestRateLimit.pause(service: service, scope: scope, until: clock().addingTimeInterval(rateLimitPause))
            throw IngestError.rateLimited(service: service, until: clock().addingTimeInterval(rateLimitPause))
        }
        let headers = Self.headers(response)
        IngestRateLimit.note(headers, service: service, scope: scope, now: clock(), pause: rateLimitPause)
        if response.statusCode == 304, let body = cached?.value["body"] {
            return IngestResponse(json: body, headers: headers, status: 304, fromCache: true)
        }
        let json = data.isEmpty ? JSONValue.null : try JSONValue.parse(data)
        if let store, let etag = headers["etag"] {
            if data.count <= etagBodyLimit {
                store.upsert([SyncedRecord(kind: Self.etagKind, scope: scope, key: etagKey,
                                           value: ["etag": .string(etag), "url": .string(url.absoluteString), "body": Sanitizer.clean(json)],
                                           source: source, updatedAt: clock())])
                trimETags(store)
            }
        }
        return IngestResponse(json: json, headers: headers, status: response.statusCode, fromCache: false)
    }

    /// GET and return the JSON.
    public func json(_ pathOrURL: String, headers: [String: String] = [:]) async throws -> JSONValue {
        try await get(pathOrURL, headers: headers).json
    }

    /// Every item of a paged list, up to `maxPages` pages. `items` picks a page's items (default:
    /// the page itself as an array).
    public func pages(_ pathOrURL: String, paging: IngestPaging, maxPages: Int = 10, headers: [String: String] = [:],
                      items: (JSONValue) -> [JSONValue]? = { $0.array }) async throws -> [JSONValue] {
        var all: [JSONValue] = []
        var next: String? = pathOrURL
        var count = 0
        while let current = next, count < maxPages {
            let page = try await get(current, headers: headers)
            all += items(page.json) ?? []
            count += 1
            next = paging.next(after: page, request: current)
        }
        return all
    }

    func resolve(_ pathOrURL: String) throws -> URL {
        if pathOrURL.hasPrefix("https://") || pathOrURL.hasPrefix("http://") {
            guard let url = URL(string: pathOrURL), connection.allows(url) else { throw ToolError("\(service): \(pathOrURL) isn't on this account's hosts.") }
            return url
        }
        guard let url = connection.url(pathOrURL) else { throw ToolError("\(service): bad path \(pathOrURL)") }
        return url
    }

    private func trimETags(_ store: any SyncedStore) {
        let records = store.records(kind: Self.etagKind, scope: scope)
        guard records.count > Self.etagLimit else { return }
        let kept = records.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.etagLimit * 4 / 5)
        store.replace(kind: Self.etagKind, scope: scope, with: Array(kept))
    }

    /// Header names in lower case.
    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { result[name.lowercased()] = value }
        }
        return result
    }
}

public struct IngestResponse: Sendable {
    public let json: JSONValue
    /// Header names in lower case.
    public let headers: [String: String]
    public let status: Int
    /// A 304: `json` is the stored copy.
    public let fromCache: Bool
}

/// How a list continues on its next page.
public enum IngestPaging: Sendable {
    /// `Link: <…>; rel="next"` (GitHub, GitLab).
    case linkHeader
    /// A token in the answer, sent back as a query parameter: Google's `nextPageToken` →
    /// `pageToken`, Jira's `nextPageToken` → `nextPageToken`.
    case token(field: String, parameter: String)
    /// A link in the answer, a path on the connection or a full URL: Confluence's
    /// `_links.next` is `.link(["_links", "next"])`.
    case link([String])

    func next(after page: IngestResponse, request: String) -> String? {
        switch self {
        case .linkHeader:
            return page.headers["link"].flatMap(Self.nextLink)
        case .token(let field, let parameter):
            guard let token = page.json[field]?.string, !token.isEmpty,
                  let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return nil }
            var components = request.components(separatedBy: "&\(parameter)=")[0]
            if let range = components.range(of: "?\(parameter)=") { components = String(components[..<range.lowerBound]) }
            return components + (components.contains("?") ? "&" : "?") + "\(parameter)=\(encoded)"
        case .link(let path):
            var value: JSONValue? = page.json
            for field in path { value = value?[field] }
            guard let link = value?.string, !link.isEmpty else { return nil }
            return link
        }
    }

    /// The `rel="next"` URL of a Link header.
    static func nextLink(_ header: String) -> String? {
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0 == #"rel="next""# }) else { continue }
            return pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        return nil
    }
}

public enum IngestError: LocalizedError, Equatable {
    case rateLimited(service: String, until: Date)

    public var errorDescription: String? {
        switch self {
        case .rateLimited(let service, let until):
            "\(service)'s rate limit is used up until \(until.formatted(date: .omitted, time: .shortened)); Dash keeps showing what it stored."
        }
    }
}

/// Services that said stop, until when (per service and scope, in this process).
@MainActor
public enum IngestRateLimit {
    private static var pausedUntil: [String: Date] = [:]

    public static func pause(service: String, scope: String, until: Date) { pausedUntil[service + "|" + scope] = until }
    public static func resume(service: String, scope: String) { pausedUntil[service + "|" + scope] = nil }
    public static func pausedUntil(service: String, scope: String, now: Date = .now) -> Date? {
        pausedUntil[service + "|" + scope].flatMap { $0 > now ? $0 : nil }
    }

    static func check(service: String, scope: String, now: Date) throws {
        if let until = pausedUntil(service: service, scope: scope, now: now) { throw IngestError.rateLimited(service: service, until: until) }
    }

    /// 429, or GitHub's 403 "API rate limit exceeded".
    static func isRateLimit(_ error: HTTPError) -> Bool {
        error.status == 429 || (error.status == 403 && error.message.localizedCaseInsensitiveContains("rate limit"))
    }

    /// A successful answer that used the last request (`x-ratelimit-remaining: 0`) pauses until
    /// `x-ratelimit-reset` (epoch seconds), else for `pause` seconds.
    static func note(_ headers: [String: String], service: String, scope: String, now: Date, pause: TimeInterval) {
        guard headers["x-ratelimit-remaining"] == "0" else { return }
        let reset = headers["x-ratelimit-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        IngestRateLimit.pause(service: service, scope: scope, until: reset.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(pause))
    }
}
