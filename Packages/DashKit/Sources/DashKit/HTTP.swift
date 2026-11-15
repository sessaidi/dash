import Foundation

public struct HTTPError: LocalizedError {
    public let service: String
    public let status: Int
    public let message: String

    public init(service: String, status: Int, message: String) {
        self.service = service
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        switch status {
        case 401: "\(service) rejected the credentials (401). Check the token in Settings."
        case 403: "\(service) denied access (403): \(message)"
        case 404: "\(service) returned not found (404): \(message)"
        default: "\(service) error \(status): \(message)"
        }
    }
}

public enum HTTP {
    /// Sends a request and throws `HTTPError` for non-2xx responses (304 is returned as-is).
    public static func send(_ request: URLRequest, service: String, session: URLSession = .shared) async throws -> (Data, HTTPURLResponse) {
        let started = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError(service: service, status: 0, message: "No HTTP response") }
        HTTPTrace.record(request, status: http.statusCode, bytes: data.count, started: started, service: service)
        DashLog.debug("\(request.httpMethod ?? "GET") \(request.url?.host() ?? "")\(request.url?.path() ?? "") → \(http.statusCode) (\(data.count) bytes)", category: "http")
        try check(data, http, service: service)
        return (data, http)
    }

    /// Throws `HTTPError` for non-2xx responses (304 passes).
    public static func check(_ data: Data, _ http: HTTPURLResponse, service: String) throws {
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            let json = try? JSONValue.parse(data)
            let message = json?["message"]?.string
                ?? json?["errorMessages"]?[0]?.string
                ?? json?["errors"]?.jsonString()
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            DashLog.error("\(service) \(http.statusCode) \(http.url?.host() ?? "")\(http.url?.path() ?? ""): \(message)", category: "http")
            throw HTTPError(service: service, status: http.statusCode, message: message)
        }
    }

    public static func request(_ url: URL, method: String = "GET", body: JSONValue? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = try body.data()
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return request
    }
}

extension Date {
    /// "5m ago", "3d ago".
    public var relative: String { formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) }
}

extension ISO8601DateFormatter {
    @available(*, deprecated, message: "Use DashDate.parse(_:)")
    nonisolated(unsafe) public static let lenient: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Kept for plugins built against DashKit 1.4; prefer `DashDate.parse(_:)`.
    public static func date(_ text: String?) -> Date? { DashDate.parse(text) }
}

/// Recent HTTP requests, for the Debug window. URLs are recorded without query strings.
public enum HTTPTrace {
    public struct Entry: Sendable, Identifiable {
        public let id = UUID()
        public let date: Date
        public let service: String
        public let method: String
        public let url: String
        public let status: Int
        public let bytes: Int
        public let milliseconds: Int
    }

    nonisolated(unsafe) private static var buffer: [Entry] = []
    private static let lock = NSLock()

    @_spi(DashHost) public static var entries: [Entry] { lock.withLock { buffer } }

    public static func record(_ request: URLRequest, status: Int, bytes: Int, started: Date, service: String) {
        var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        components?.query = nil
        let entry = Entry(date: Date(), service: service, method: request.httpMethod ?? "GET", url: components?.string ?? "?",
                          status: status, bytes: bytes, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        lock.withLock {
            buffer.append(entry)
            if buffer.count > 500 { buffer.removeFirst(buffer.count - 500) }
        }
    }
}
