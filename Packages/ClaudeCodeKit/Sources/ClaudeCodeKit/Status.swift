import Foundation

/// Who is logged in to Claude Code (`claude auth status`).
public struct ClaudeAuthStatus: Codable, Sendable, Equatable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var apiProvider: String?
    public var email: String?
    public var orgName: String?
    public var subscriptionType: String?
}

/// `/usage` as Claude Code prints it: what's using up the plan's limits, per time window.
public struct ClaudeUsageReport: Sendable, Equatable {
    /// "You are currently using your subscription…", the first line.
    public var plan: String
    public var windows: [Window]

    public struct Window: Sendable, Equatable {
        /// "Last 24h", "Last 7d".
        public var label: String
        public var requests: Int?
        public var sessions: Int?
        /// Claude Code's suggestions, with the share of usage each concerns.
        public var tips: [Share]
        /// "skills", "subagents", "MCP servers" to their top entries.
        public var top: [String: [Share]]
    }

    public struct Share: Sendable, Equatable {
        public var percent: Int
        public var text: String
    }

    /// Parses the text `/usage` prints. Unknown lines are skipped, so a changed format degrades
    /// to fewer fields rather than an error.
    public static func parse(_ text: String) -> ClaudeUsageReport {
        var report = ClaudeUsageReport(plan: "", windows: [])
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if report.plan.isEmpty, report.windows.isEmpty, line.lowercased().contains("using") {
                report.plan = line
            } else if line.hasPrefix("Last ") {
                // "Last 24h · 779 requests · 7 sessions"
                let parts = line.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                var window = Window(label: parts[0], requests: nil, sessions: nil, tips: [], top: [:])
                for part in parts.dropFirst() {
                    let words = part.split(separator: " ")
                    guard words.count >= 2, let count = Int(words[0].replacingOccurrences(of: ",", with: "")) else { continue }
                    if words[1].hasPrefix("request") { window.requests = count }
                    if words[1].hasPrefix("session") { window.sessions = count }
                }
                report.windows.append(window)
            } else if !report.windows.isEmpty, line.hasPrefix("Top "), let colon = line.firstIndex(of: ":") {
                // "Top subagents: general-purpose 19%, Explore 1%"
                let category = String(line[line.index(line.startIndex, offsetBy: 4)..<colon])
                let entries = line[line.index(after: colon)...].split(separator: ",").compactMap { entry -> Share? in
                    let trimmed = entry.trimmingCharacters(in: .whitespaces)
                    guard let space = trimmed.lastIndex(of: " "), trimmed.hasSuffix("%"),
                          let percent = Int(trimmed[trimmed.index(after: space)...].dropLast()) else { return nil }
                    return Share(percent: percent, text: String(trimmed[..<space]))
                }
                report.windows[report.windows.count - 1].top[category] = entries
            } else if !report.windows.isEmpty, let percentSign = line.firstIndex(of: "%"), let percent = Int(line[..<percentSign]) {
                // "98%  Give "general-purpose" subagents a cheaper model"
                let tip = line[line.index(after: percentSign)...].trimmingCharacters(in: .whitespaces)
                report.windows[report.windows.count - 1].tips.append(Share(percent: percent, text: tip))
            }
        }
        return report
    }
}

/// Reads Claude Code's own status: version, login, and `/usage`. Each call runs the CLI once.
public enum ClaudeCodeStatus {
    /// "2.1.311" from `claude --version`.
    public static func version(executable: URL? = nil) async throws -> String {
        let output = try await run(["--version"], executable: executable)
        return output.split(separator: " ").first.map(String.init) ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func auth(executable: URL? = nil) async throws -> ClaudeAuthStatus {
        let output = try await run(["auth", "status"], executable: executable)
        return try JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(output.utf8))
    }

    /// Runs `/usage` headlessly (`claude -p /usage --output-format json`); no model call, no cost.
    public static func usage(executable: URL? = nil) async throws -> ClaudeUsageReport {
        let output = try await run(["-p", "/usage", "--output-format", "json", "--no-session-persistence"], executable: executable)
        let json = try JSON.parse(output)
        guard let text = json["result"]?.string else { throw ClaudeCodeError.controlRequestFailed("/usage returned no result") }
        return ClaudeUsageReport.parse(text)
    }

    static func run(_ arguments: [String], executable: URL?) async throws -> String {
        guard let executable = executable ?? Locator.claude() else { throw ClaudeCodeError.executableNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Locator.searchPath.joined(separator: ":")
            // The status of the Claude login, not of an API key that may be set for other tools.
            environment.removeValue(forKey: "ANTHROPIC_API_KEY")
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: ClaudeCodeError.processExited(status: process.terminationStatus, stderr: text))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// The plan-limit meters interactive `/usage` shows: usage credits (spend against a monthly
/// budget), or the session and weekly limits of Pro and Max plans.
public struct ClaudePlanLimits: Sendable, Equatable {
    public struct Meter: Sendable, Equatable {
        /// "Usage credits", "Current session", "Current week (all models)"…
        public var title: String
        public var percentUsed: Int?
        /// Credits: dollars spent and the budget.
        public var spent: Double?
        public var limit: Double?
        /// "Dec 1 (Europe/Paris)", "3pm (Europe/Paris)".
        public var resets: String?

        public init(title: String, percentUsed: Int? = nil, spent: Double? = nil, limit: Double? = nil, resets: String? = nil) {
            self.title = title
            self.percentUsed = percentUsed
            self.spent = spent
            self.limit = limit
            self.resets = resets
        }
    }

    public var meters: [Meter]

    static let titles = ["Usage credits", "Extra usage", "Current session", "Current week (all models)",
                         "Current week (Opus)", "Current week (Sonnet)", "Current week"]

    /// Parses the panel's text (ANSI already stripped). The last occurrence of each meter wins,
    /// since the terminal redraws the panel.
    public static func parse(_ text: String) -> ClaudePlanLimits {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        var found: [(range: Range<String.Index>, title: String)] = []
        for title in titles {
            guard let range = flat.range(of: title, options: .backwards),
                  !found.contains(where: { $0.range.overlaps(range) || $0.title.hasPrefix(title) }) else { continue }
            found.append((range, title))
        }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        var meters: [Meter] = []
        for (index, item) in found.enumerated() {
            let end = index + 1 < found.count ? found[index + 1].range.lowerBound : flat.endIndex
            var segment = String(flat[item.range.upperBound..<end])
            if let stop = segment.range(of: "Esc to") { segment = String(segment[..<stop.lowerBound]) }
            var meter = Meter(title: item.title)
            if let match = segment.firstMatch(of: /(\d{1,3})\s*%\s*used/) { meter.percentUsed = Int(match.output.1) }
            if let match = segment.firstMatch(of: /\$([\d,]+(?:\.\d+)?)\s*\/\s*\$([\d,]+(?:\.\d+)?)\s*spent/) {
                meter.spent = Double(match.output.1.replacingOccurrences(of: ",", with: ""))
                meter.limit = Double(match.output.2.replacingOccurrences(of: ",", with: ""))
            }
            if let match = segment.firstMatch(of: /Resets\s+(.+?\))/) ?? segment.firstMatch(of: /Resets\s+([^·]+?)(?:\s{2,}|$)/) {
                meter.resets = String(match.output.1).trimmingCharacters(in: .whitespaces)
            }
            if meter.percentUsed != nil || meter.spent != nil { meters.append(meter) }
        }
        return ClaudePlanLimits(meters: meters)
    }
}

extension ClaudeCodeStatus {
    /// Opens Claude Code in a pseudo-terminal, runs `/usage` and reads the plan-limit meters
    /// (headless `-p /usage` leaves them out). Runs in `folder`; if Claude Code asks whether to
    /// trust it, the folder is trusted (it's Dash's own, empty). No model call, no cost.
    public static func planLimits(executable: URL? = nil, folder: URL) async throws -> ClaudePlanLimits {
        guard let executable = executable ?? Locator.claude() else { throw ClaudeCodeError.executableNotFound }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = try await Task.detached { try TerminalSession.usagePanel(executable: executable, folder: folder) }.value
        return ClaudePlanLimits.parse(text)
    }
}

/// Just enough terminal to drive Claude Code's interactive `/usage` panel.
enum TerminalSession {
    static func usagePanel(executable: URL, folder: URL) throws -> String {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            throw ClaudeCodeError.processExited(status: -1, stderr: "Couldn't open a pseudo-terminal.")
        }
        defer { close(master) }
        let slave = FileHandle(forUpdatingAtPath: String(cString: name))
        guard let slave else { throw ClaudeCodeError.processExited(status: -1, stderr: "Couldn't open the terminal's slave side.") }
        // Tall and wide, so the whole panel (credits are at the bottom) fits without scrolling.
        var size = winsize(ws_row: 120, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave.fileDescriptor, TIOCSWINSZ, &size)
        _ = ioctl(master, TIOCSWINSZ, &size)

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Locator.searchPath.joined(separator: ":")
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = "160"
        environment["LINES"] = "120"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        var output = Data()
        func read(for seconds: Double, until done: ((String) -> Bool)? = nil) {
            let end = Date().addingTimeInterval(seconds)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while Date() < end {
                var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 200) > 0 else { continue }
                let count = Darwin.read(master, &buffer, buffer.count)
                if count <= 0 { return }
                output.append(buffer, count: count)
                if let done, done(render(output)) { return }
            }
        }
        func write(_ text: String) { _ = text.withCString { Darwin.write(master, $0, strlen($0)) } }

        read(for: 10) { $0.contains("trust this folder") || $0.contains("? for shortcuts") || $0.contains(">") && $0.count > 400 }
        if render(output).contains("trust this folder") {
            write("\u{1B}[B")
            read(for: 0.5)
            write("\r")
            read(for: 8) { $0.contains("? for shortcuts") }
        }
        write("/usage")
        read(for: 1.5)
        write("\r")
        read(for: 15) { text in text.contains("% used") && text.range(of: "Resets", options: .backwards) != nil }
        read(for: 1)
        write("\u{1B}")
        return render(output)
    }

    /// The terminal output as plain text: cursor-forward moves become spaces, other escape
    /// sequences are dropped.
    static func render(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacing(/\x1B\[(\d*)C/) { String(repeating: " ", count: Int($0.output.1) ?? 1) }
        // Other cursor positioning (column, row/column) separates words too.
        text = text.replacing(/\x1B\[[0-9;]*[GHf]/, with: " ")
        text = text.replacing(/\x1B\[[0-9;?<>=]*[ -\/]*[@-~]/, with: "")
        text = text.replacing(/\x1B[\]P^_][^\x07\x1B]*(\x07|\x1B\\)/, with: "")
        text = text.replacing(/\x1B[()][0-9A-Za-z]/, with: "")
        return text
    }
}
