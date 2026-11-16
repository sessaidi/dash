import Foundation

/// Dash's own crash reports, read from what macOS writes (`~/Library/Logs/DiagnosticReports/Dash-*.ips`).
/// Nothing is sent anywhere: Dash shows them after a crash and in the Debug window.
struct CrashReport: Identifiable, Equatable, Sendable {
    let id: String
    let file: URL
    let date: Date
    let version: String
    /// "EXC_BREAKPOINT (SIGTRAP)", "EXC_BAD_ACCESS (SIGSEGV)"…
    let exception: String
    /// Swift's message when it stopped on purpose ("Fatal error: Index out of range"), or the
    /// termination reason ("Library missing").
    let reason: String
    /// The crashed thread's frames in Dash's own code first, then the rest: "symbol (File.swift:12)".
    let frames: [String]

    /// A few lines to read, copy or hand to Dashii.
    var summary: String {
        var lines = ["Dash \(version) crashed on \(date.formatted(date: .abbreviated, time: .standard))", exception]
        if !reason.isEmpty { lines.append(reason) }
        lines.append(contentsOf: frames.prefix(12).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    /// Parses an `.ips` file: one JSON header line, then the JSON report.
    static func parse(_ text: String, file: URL, modified: Date) -> CrashReport? {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else { return nil }
        let exception = body["exception"] as? [String: Any]
        let type = exception?["type"] as? String ?? "Crash"
        let signal = exception?["signal"] as? String
        // Swift's fatal error message, else what dyld or the system said.
        var reason = ""
        if let asi = body["asi"] as? [String: [String]] { reason = asi.values.flatMap { $0 }.first { !$0.isEmpty } ?? "" }
        if reason.isEmpty, let termination = body["termination"] as? [String: Any] {
            reason = ((termination["reasons"] as? [String])?.first) ?? (termination["indicator"] as? String) ?? ""
        }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true } ?? threads.first
        let frames: [(own: Bool, text: String)] = ((crashed?["frames"] as? [[String: Any]]) ?? []).map { frame in
            let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
            var text = frame["symbol"] as? String ?? "?"
            if let source = frame["sourceFile"] as? String, !source.isEmpty {
                text += " (\(source)\((frame["sourceLine"] as? Int).map { ":\($0)" } ?? ""))"
            }
            return (image == "Dash" || image.hasPrefix("Dash") || image == "DashKit", "\(image): \(text)")
        }
        let date = (body["captureTime"] as? String).flatMap(Self.captureDate) ?? (header["timestamp"] as? String).flatMap(Self.captureDate) ?? modified
        return CrashReport(id: file.lastPathComponent, file: file, date: date,
                           version: header["app_version"] as? String ?? "?",
                           exception: signal.map { "\(type) (\($0))" } ?? type, reason: reason,
                           frames: frames.filter(\.own).map(\.text) + frames.filter { !$0.own }.prefix(6).map(\.text))
    }

    /// "2026-11-15 23:45:27.3311 +0100"
    static func captureDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSS Z", "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

enum CrashReports {
    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports") }

    /// Dash's crash reports, newest first (at most `limit`).
    static func all(in folder: URL = folder, limit: Int = 20) -> [CrashReport] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Dash-") && $0.pathExtension == "ips" }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return dated.compactMap { file, modified in
            (try? String(contentsOf: file, encoding: .utf8)).flatMap { CrashReport.parse($0, file: file, modified: modified) }
        }
    }

    /// Crashes newer than the last one the user saw.
    static func unseen(in folder: URL = folder, defaults: UserDefaults) -> [CrashReport] {
        // Before the first check, only recent crashes count (not every report macOS ever kept).
        let seen = defaults.object(forKey: "health.crashesSeen") as? Date ?? Date.now.addingTimeInterval(-3 * 86_400)
        return all(in: folder).filter { $0.date > seen }
    }

    static func markSeen(_ reports: [CrashReport], defaults: UserDefaults) {
        if let newest = reports.map(\.date).max() { defaults.set(newest, forKey: "health.crashesSeen") }
    }
}
