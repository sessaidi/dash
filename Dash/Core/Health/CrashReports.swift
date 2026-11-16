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
    /// The executable that crashed: the installed app, or a development build (tests run in one).
    var processPath = ""
    /// The crashed thread's frames, structured, Dash's own first.
    var details: [Frame] = []

    struct Frame: Equatable, Sendable {
        let image: String
        let symbol: String
        let file: String?
        let line: Int?
        /// In Dash's code (the app or DashKit), not the system's.
        let own: Bool

        /// The function as a person would name it: without "closure #1 in", "specialized",
        /// "partial apply for" or generic parameters.
        var name: String {
            var text = symbol
            for noise in ["partial apply for ", "specialized ", "protocol witness for ", "implicit closure #1 in ", "static "] {
                text = text.replacingOccurrences(of: noise, with: "")
            }
            text = text.replacingOccurrences(of: #"closure #\d+ in "#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"<[^<>]*>"#, with: "", options: .regularExpression)
            return text.trimmingCharacters(in: .whitespaces)
        }

        /// "ChatPanel.swift:276", nil without a known source file.
        var place: String? {
            guard let file, !file.isEmpty, !file.contains("<"), !file.contains("@__swiftmacro") else { return nil }
            return (file as NSString).lastPathComponent + (line.map { ":\($0)" } ?? "")
        }
    }

    /// What happened, in plain words.
    var explanation: String {
        if reason.hasPrefix("Fatal error:") || reason.hasPrefix("Swift/") || reason.contains("Fatal error") {
            return "Dash stopped itself on purpose because something impossible happened: \(reason.replacingOccurrences(of: "Fatal error: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines))."
        }
        if exception.hasPrefix("EXC_BAD_ACCESS") { return "Dash read or wrote memory it no longer owned (a use-after-free or a bad pointer)." }
        if reason.contains("Update Constraints in Window") {
            return "A window's layout kept changing its own size in a loop, and macOS stopped Dash. A view's size depended on itself."
        }
        if exception.contains("uncaught exception") { return "macOS stopped Dash on an error it couldn't recover from: \(reason)" }
        if reason.contains("Library not loaded") || reason == "Library missing" { return "A framework Dash needs was missing when it started." }
        if exception.contains("SIGTRAP") || exception.contains("EXC_BREAKPOINT") {
            return "Dash hit a safety check and stopped (for example a value used from the wrong thread, or a forced unwrap of nothing)."
        }
        if exception.contains("SIGABRT") { return "Dash was stopped by an internal assertion\(reason.isEmpty ? "" : ": " + reason)." }
        return reason.isEmpty ? "Dash stopped unexpectedly (\(exception))." : reason
    }

    /// Where in Dash's code it happened: its own frames, deduplicated by name, at most `limit`.
    func places(limit: Int = 5) -> [Frame] {
        var seen = Set<String>()
        return details.filter(\.own).filter { seen.insert($0.name).inserted }.prefix(limit).map { $0 }
    }

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
        let rawFrames = (crashed?["frames"] as? [[String: Any]]) ?? []
        let details: [Frame] = rawFrames.map { frame in
            let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
            return Frame(image: image, symbol: frame["symbol"] as? String ?? "?", file: frame["sourceFile"] as? String,
                         line: frame["sourceLine"] as? Int, own: Self.isOwn(image: image, symbol: frame["symbol"] as? String ?? ""))
        }
        let frames: [(own: Bool, text: String)] = rawFrames.map { frame in
            let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
            var text = frame["symbol"] as? String ?? "?"
            if let source = frame["sourceFile"] as? String, !source.isEmpty {
                text += " (\(source)\((frame["sourceLine"] as? Int).map { ":\($0)" } ?? ""))"
            }
            return (Self.isOwn(image: image, symbol: frame["symbol"] as? String ?? ""), "\(image): \(text)")
        }
        let date = (body["captureTime"] as? String).flatMap(Self.captureDate) ?? (header["timestamp"] as? String).flatMap(Self.captureDate) ?? modified
        return CrashReport(id: file.lastPathComponent, file: file, date: date,
                           version: header["app_version"] as? String ?? "?",
                           exception: signal.map { "\(type) (\($0))" } ?? type, reason: reason,
                           frames: frames.filter(\.own).map(\.text) + frames.filter { !$0.own }.prefix(6).map(\.text),
                           processPath: body["procPath"] as? String ?? "",
                           details: details.filter(\.own) + details.filter { !$0.own })
    }

    /// Dash's own code (the app, its debug dylib, DashKit), not tests, macros or the system.
    static func isOwn(image: String, symbol: String) -> Bool {
        (image == "Dash" || image.hasPrefix("Dash.") || image.hasPrefix("DashKit")) && !image.contains("Tests")
            && !symbol.hasPrefix("$s") && !symbol.contains("macro expansion")
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
    /// Where the uncaught-exception handler writes, one file per exception.
    static var exceptionsFolder: URL { URL.applicationSupportDirectory.appending(path: "Dash/Exceptions") }

    /// Saves an uncaught exception as a small `.ips`-like report Dash reads like macOS's own.
    nonisolated static func saveException(_ exception: NSException, to folder: URL = exceptionsFolder) {
        let now = Date.now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        let header: [String: Any] = ["app_name": "Dash", "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"]
        let frames: [[String: Any]] = exception.callStackSymbols.map { ["imageIndex": 0, "symbol": Self.symbol(fromCallStackLine: $0)] }
        let body: [String: Any] = [
            "captureTime": formatter.string(from: now), "procPath": Bundle.main.executablePath ?? "",
            "exception": ["type": exception.name.rawValue, "signal": "uncaught exception"],
            "asi": ["AppKit": [exception.reason ?? ""]],
            "usedImages": [["name": "Dash"]], "threads": [["triggered": true, "frames": frames]],
        ]
        guard let head = try? JSONSerialization.data(withJSONObject: header), let rest = try? JSONSerialization.data(withJSONObject: body) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Dash-exception-\(Int(now.timeIntervalSince1970)).ips"
        try? (head + Data("\n".utf8) + rest).write(to: folder.appending(path: name))
    }

    /// "3   AppKit   0x00000001a0ffb778 -[NSWindow …] + 1716" → "AppKit: -[NSWindow …]"
    nonisolated static func symbol(fromCallStackLine line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return line }
        let image = parts[1]
        var symbol = parts.dropFirst(3).joined(separator: " ")
        if let plus = symbol.range(of: " + ", options: .backwards) { symbol = String(symbol[..<plus.lowerBound]) }
        return "\(image): \(symbol)"
    }

    /// The running app's executable: only its crashes count (development builds and test runs
    /// crash on their own, from another path).
    static var currentExecutable: String { Bundle.main.executablePath ?? "" }

    /// Dash's crash reports, newest first (at most `limit`); with `executable`, only that app's.
    static func all(in folder: URL = folder, limit: Int = 20, executable: String? = currentExecutable) -> [CrashReport] {
        let folders = folder == Self.folder ? [folder, exceptionsFolder] : [folder]
        let files = folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("Dash-") && $0.pathExtension == "ips" }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return dated.compactMap { file, modified in
            (try? String(contentsOf: file, encoding: .utf8)).flatMap { CrashReport.parse($0, file: file, modified: modified) }
        }.filter { report in
            guard let executable, !executable.isEmpty, !report.processPath.isEmpty else { return true }
            return report.processPath == executable || report.processPath == anonymized(executable)
        }
    }

    /// How macOS writes a path under the home folder in a report: "/Users/USER/*/Dash.app/Contents/MacOS/Dash".
    static func anonymized(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard path.hasPrefix(home + "/"), let app = path.range(of: #"[^/]+\.app/"#, options: .regularExpression) else { return path }
        return "/Users/USER/*/" + path[app.lowerBound...]
    }

    /// Crashes newer than the last one the user saw.
    static func unseen(in folder: URL = folder, defaults: UserDefaults, executable: String? = currentExecutable) -> [CrashReport] {
        // Before the first check, only recent crashes count (not every report macOS ever kept).
        let seen = defaults.object(forKey: "health.crashesSeen") as? Date ?? Date.now.addingTimeInterval(-3 * 86_400)
        return all(in: folder, executable: executable).filter { $0.date > seen }
    }

    static func markSeen(_ reports: [CrashReport], defaults: UserDefaults) {
        if let newest = reports.map(\.date).max() { defaults.set(newest, forKey: "health.crashesSeen") }
    }
}
