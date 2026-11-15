import Foundation

/// Dates and numbers as APIs and people write them, parsed and printed one way everywhere in
/// DashKit and its plugins.
public enum DashDate {
    // ISO8601DateFormatter is thread-safe once configured; these are never mutated.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    /// Jira's "2024-01-02T03:04:05.000+0000" (no colon in the offset).
    nonisolated(unsafe) private static let compactOffset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    /// An API timestamp: ISO 8601 with or without fractional seconds, Jira's compact offset, or
    /// (as people type them) "2026-10-12", "2026-10-12 14:00" or "2026-10-12T14:00" in the
    /// user's time zone. Seconds since 1970 (or milliseconds) work too, via `parse(_: JSONValue)`.
    public static func parse(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.count >= 10 else { return nil }
        if let date = plain.date(from: text) ?? fractional.date(from: text) ?? compactOffset.date(from: text) { return date }
        return local(text)
    }

    /// A row value as a date: text as in `parse`, or a number of seconds (or milliseconds) since 1970.
    public static func parse(_ value: JSONValue) -> Date? {
        switch value {
        case .string(let text): parse(text)
        case .number(let seconds) where seconds > 1_000_000_000:
            Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1000 : seconds)
        default: nil
        }
    }

    /// "2026-10-12" (start of that day) or "2026-10-12 14:30[:05]" in the user's time zone.
    static func local(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        guard parts.count >= 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        if parts.count >= 5 { components.hour = parts[3]; components.minute = parts[4] }
        if parts.count >= 6 { components.second = parts[5] }
        return Calendar.current.date(from: components)
    }

    /// A number as people read it: whole numbers without ".0", never trapping on huge values.
    public static func number(_ value: Double) -> String {
        if let whole = Int(exactly: value) { return String(whole) }
        return String(value)
    }
}
