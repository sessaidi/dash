import Foundation

/// Your environment as your terminal sees it. Apps opened from the Dock or Finder only get a
/// minimal one, so variables your shell config exports (DOCKER_HOST, KUBECONFIG, AWS_PROFILE,
/// GOOGLE_APPLICATION_CREDENTIALS, PATH additions…) are missing. This reads them once from your
/// login shell (bash, zsh or fish) and fills in what Dash's own environment lacks.
///
/// Integrations look here first, then at their default paths:
/// ```swift
/// let kubeconfig = ShellEnvironment.value("KUBECONFIG") ?? "~/.kube/config"
/// ```
public enum ShellEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: String]?

    /// Dash's environment, with your login shell's variables added where Dash has none.
    public static var current: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in shell where environment[key] == nil { environment[key] = value }
        // PATH: Dash's, then the shell's extra entries (Homebrew, ~/go/bin…).
        if let shellPath = shell["PATH"] {
            let mine = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let extra = shellPath.split(separator: ":").map(String.init).filter { !mine.contains($0) }
            environment["PATH"] = (mine + extra).joined(separator: ":")
        }
        return environment
    }

    /// One variable: Dash's own, else your login shell's.
    public static func value(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 } ?? shell[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The login shell's environment, read once (empty if it can't be read within a few seconds).
    public static var shell: [String: String] {
        lock.withLock {
            if let loaded { return loaded }
            let result = read()
            loaded = result
            return result
        }
    }

    /// Forgets what was read (after you change your shell config).
    public static func reload() { lock.withLock { loaded = nil } }

    static let marker = "__DASH_ENV__"

    private static func read() -> [String: String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // Login + interactive, so .bash_profile/.bashrc, .zprofile/.zshrc or fish's config run;
        // the marker separates the environment from anything the config prints.
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)'; /usr/bin/env -0"]
        // A clean start, like a new terminal: configs that skip work when already loaded still run.
        let home = NSHomeDirectory()
        process.environment = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": shellPath,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb", "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let reader = output.fileHandleForReading
        let collected = Collector()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.data = reader.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            return [:]
        }
        process.waitUntilExit()
        return parse(collected.data)
    }

    private final class Collector: @unchecked Sendable { var data = Data() }

    /// NUL-separated KEY=VALUE pairs after the marker.
    static func parse(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: marker) else { return [:] }
        var result: [String: String] = [:]
        for entry in text[range.upperBound...].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            guard !key.isEmpty, !key.hasPrefix("BASH_FUNC_") else { continue }
            result[key] = String(entry[entry.index(after: equals)...])
        }
        // Per-session values that don't belong to Dash.
        for transient in ["_", "SHLVL", "PWD", "OLDPWD", "TERM", "PS1", "PROMPT_COMMAND"] { result[transient] = nil }
        return result
    }
}
