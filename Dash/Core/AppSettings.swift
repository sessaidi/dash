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
    /// Path to the `claude` CLI; empty = search PATH and the usual install locations.
    var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    /// Verbose logging (every HTTP request) and the Debug menu.
    var debugMode: Bool {
        didSet {
            defaults.set(debugMode, forKey: "debugMode")
            DashLog.verbose = debugMode
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.string(forKey: "model") ?? "claude-opus-5-5"
        effort = defaults.string(forKey: "effort") ?? "medium"
        confirmWrites = defaults.object(forKey: "confirmWrites") as? Bool ?? true
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
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
