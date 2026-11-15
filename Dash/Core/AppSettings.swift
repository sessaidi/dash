import DashKit
import DashKitUI
import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    @ObservationIgnored private let defaults: UserDefaults

    var model: String { didSet { defaults.set(model, forKey: "model") } }
    var effort: String { didSet { defaults.set(effort, forKey: "effort") } }
    /// Ask before Claude runs a tool that writes to GitHub/Jira or deletes something.
    var confirmWrites: Bool { didSet { defaults.set(confirmWrites, forKey: "confirmWrites") } }
    /// Dashii gets the `dash` statements tool (and the chat's own) instead of every tool:
    /// far fewer tokens per turn; everything stays reachable through it.
    var compactTools: Bool { didSet { defaults.set(compactTools, forKey: "compactTools") } }
    /// Path to the `claude` CLI; empty = search PATH and the usual install locations.
    var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    /// Verbose logging (every HTTP request) and the Debug menu.
    var debugMode: Bool {
        didSet {
            defaults.set(debugMode, forKey: "debugMode")
            DashLog.verbose = debugMode
        }
    }

    init(defaults: UserDefaults = DashDefaults.shared) {
        self.defaults = defaults
        model = defaults.string(forKey: "model") ?? "claude-opus-5-5"
        effort = defaults.string(forKey: "effort") ?? "medium"
        confirmWrites = defaults.object(forKey: "confirmWrites") as? Bool ?? true
        compactTools = defaults.object(forKey: "compactTools") as? Bool ?? true
        debugMode = defaults.bool(forKey: "debugMode")
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        DashLog.verbose = debugMode
    }

    /// The CLI Dash will run for the Claude Code backend, if it can find one.
    var claudeExecutable: URL? {
        if !claudePath.isEmpty { return URL(filePath: (claudePath as NSString).expandingTildeInPath) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { URL(filePath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Ready to talk to Claude: the Claude Code CLI is installed.
    var isClaudeConfigured: Bool { claudeExecutable != nil }

}

/// Small helper so extensions can persist their own preferences.
@MainActor
struct Preference<Value> {
    let key: String
    let defaultValue: Value

    var value: Value {
        get { DashDefaults.shared.object(forKey: key) as? Value ?? defaultValue }
        nonmutating set { DashDefaults.shared.set(newValue, forKey: key) }
    }
}


/// Dash's preferences, and every plugin's (`DashStorage.defaults`), kept in Dash's database.
/// Under tests they live in memory, so a test run never changes the user's settings.
enum DashDefaults {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    nonisolated(unsafe) static let shared: UserDefaults = make()

    private static func make() -> UserDefaults {
        if isTesting { return (try? DatabaseDefaults(url: nil)) ?? UserDefaults(suiteName: "dev.sessaidi.Dash.tests")! }
        do {
            try FileManager.default.createDirectory(at: DatabaseDefaults.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let defaults = try DatabaseDefaults(url: DatabaseDefaults.fileURL)
            defaults.importOnce(from: UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "dev.sessaidi.Dash") ?? [:])
            return defaults
        } catch {
            DashLog.error("Couldn't open the preferences database, using the plist: \(error)", category: "preferences")
            return .standard
        }
    }
}
