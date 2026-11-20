import DashKit
import Foundation

/// How `IngestClient` tries a request again when it failed for a passing reason (the server
/// failed or timed out, the network dropped): after `base` seconds, then twice as long each time,
/// at most `maxDelay`, give or take `jitter`; `attempts` tries in all. Rate limits aren't retried:
/// they pause the account until they reset (`IngestRateLimit`).
public struct IngestRetry: Sendable, Equatable {
    public var attempts: Int
    public var base: TimeInterval
    public var maxDelay: TimeInterval
    /// 0.2: each wait is 80 to 120 % of the exponential one.
    public var jitter: Double

    public init(attempts: Int = 3, base: TimeInterval = 0.5, maxDelay: TimeInterval = 8, jitter: Double = 0.2) {
        self.attempts = max(1, attempts)
        self.base = base
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// Three tries: after about 0.5 s and 1 s.
    public static let standard = IngestRetry()
    /// One try.
    public static let none = IngestRetry(attempts: 1)

    /// The wait after try number `attempt` (from 1); `random` in -1...1.
    public func delay(after attempt: Int, random: Double = .random(in: -1...1)) -> TimeInterval {
        let exponential = min(maxDelay, base * pow(2, Double(max(0, attempt - 1))))
        return max(0, exponential * (1 + jitter * random))
    }

    /// Worth trying again: 408, 500, 502, 503, 504, no HTTP answer, or a dropped or unreachable network.
    public static func isTransient(_ error: any Error) -> Bool {
        if let http = error as? HTTPError { return [0, 408, 500, 502, 503, 504].contains(http.status) }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(url.code)
        }
        return false
    }
}
