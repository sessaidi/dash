import AppKit
import CryptoKit
import DashKit
import Foundation
import Observation

/// Updates Dash from the GitHub releases of its repository (`DashUpdateRepository` in the
/// Info.plist, changeable in Settings › Updates), or from a local folder: a Dash checkout whose
/// `dist/` holds the zips `scripts/release.sh` builds. A GitHub release is tagged `v<version>` and
/// carries `Dash-<version>.zip`. Installing downloads the zip, checks it is Dash at that version with a
/// valid signature (and GitHub's SHA-256 of the asset when it gives one), then quits: a small
/// script waits for Dash to exit, swaps the bundle in place and opens the new one.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL?
        let asset: Asset
    }

    struct Asset: Equatable {
        let name: String
        /// The API URL: works for private repositories with a token. A local zip has none.
        let apiURL: URL?
        /// The download, or the zip itself for a local folder.
        let downloadURL: URL
        /// "sha256:…" when GitHub has computed it.
        let digest: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date?

    var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: "updates.automatic") }
    }

    /// Where releases come from: "owner/name" (or a GitHub URL) or a local folder path.
    var source: String {
        didSet { defaults.set(source, forKey: "updates.source") }
    }
    static let defaultSource = Bundle.main.object(forInfoDictionaryKey: "DashUpdateRepository") as? String ?? "sessaidi/dash"
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Debug builds run from the build folder: they check, but never replace themselves.
    var canInstall: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var token: String?

    init(defaults: UserDefaults = DashDefaults.shared) {
        self.defaults = defaults
        automaticChecks = defaults.object(forKey: "updates.automatic") as? Bool ?? true
        source = defaults.string(forKey: "updates.source") ?? Self.defaultSource
    }

    enum Source: Equatable {
        case github(String)
        case local(URL)
    }

    /// "owner/name", "https://github.com/owner/name", "git@github.com:owner/name.git", or a
    /// path starting with "/" or "~".
    nonisolated static func parse(_ text: String) -> Source? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return .local(URL(filePath: (text as NSString).expandingTildeInPath, directoryHint: .isDirectory))
        }
        var repo = text
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:", "github.com/"] where repo.hasPrefix(prefix) {
            repo = String(repo.dropFirst(prefix.count))
        }
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        if repo.hasSuffix("/") { repo = String(repo.dropLast()) }
        let parts = repo.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        return .github(repo)
    }

    /// Checks now, then every six hours while automatic checks are on.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticChecks { await self.check(quietly: true) }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Looks up the latest release. `quietly` keeps a failure from replacing an offer on screen.
    func check(quietly: Bool = false) async {
        if case .installing = state { return }
        let previous = state
        state = .checking
        do {
            let release = try await latestRelease()
            lastCheck = .now
            state = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            DashLog.error("Update check failed: \(error.localizedDescription)", category: "updates")
            state = quietly ? (previous == .checking ? .idle : previous) : .failed(error.localizedDescription)
        }
    }

    /// Downloads and checks the release, then quits and relaunches into it.
    func install(_ release: Release) async {
        guard canInstall else { state = .failed("Debug builds don't install updates; build a release with scripts/release.sh."); return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .failed("Dash can't write to \(target.deletingLastPathComponent().path).")
            return
        }
        do {
            state = .installing("Downloading \(release.asset.name)…")
            let zip = try await download(release.asset)
            state = .installing("Checking the download…")
            let app = try await unpack(zip, expecting: release.version)
            state = .installing("Relaunching…")
            try relaunch(replacing: target, with: app)
            NSApp.terminate(nil)
        } catch {
            DashLog.error("Update failed: \(error.localizedDescription)", category: "updates")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - GitHub

    private func latestRelease() async throws -> Release {
        switch Self.parse(source) {
        case .github(let repository): try await latestRelease(github: repository)
        case .local(let folder): try Self.latestRelease(in: folder)
        case nil: throw UpdateError("“\(source)” is neither owner/name nor a folder path.")
        }
    }

    /// The newest `Dash-<version>.zip` in a folder or its `dist/`.
    nonisolated static func latestRelease(in folder: URL) throws -> Release {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { throw UpdateError("\(folder.path) doesn't exist.") }
        let zips = [folder, folder.appending(path: "dist")].flatMap { directory in
            ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Dash-") && $0.pathExtension == "zip" }
        }
        let versions = zips.map { zip in (zip, String(zip.deletingPathExtension().lastPathComponent.dropFirst("Dash-".count))) }
        guard let (zip, version) = versions.max(by: { isNewer($1.1, than: $0.1) }) else {
            throw UpdateError("No Dash-….zip in \(folder.path) or its dist/. Build one with scripts/release.sh.")
        }
        return Release(version: version, notes: "", page: nil,
                       asset: Asset(name: zip.lastPathComponent, apiURL: nil, downloadURL: zip, digest: nil))
    }

    private func latestRelease(github repository: String) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var (data, status) = try await get(url, token: token)
        // A private repository answers 404 without a token: retry with the GitHub CLI's.
        if status == 404, token == nil, let found = Self.ghToken() {
            token = found
            (data, status) = try await get(url, token: found)
        }
        switch status {
        case 200: break
        case 404: throw UpdateError("No release found in \(repository). Is the repository private and `gh` not logged in?")
        default: throw UpdateError("GitHub answered \(status).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError("GitHub sent an unexpected answer.") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasPrefix("Dash-") == true && ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let name = asset["name"] as? String,
              let api = (asset["url"] as? String).flatMap(URL.init(string:)),
              let download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError("Release \(tag) has no Dash-….zip.") }
        return Release(version: version, notes: json["body"] as? String ?? "",
                       page: (json["html_url"] as? String).flatMap(URL.init(string:)),
                       asset: Asset(name: name, apiURL: api, downloadURL: download, digest: asset["digest"] as? String))
    }

    private func get(_ url: URL, token: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func download(_ asset: Asset) async throws -> URL {
        let zip = FileManager.default.temporaryDirectory.appending(path: "dash-update-\(UUID().uuidString).zip")
        if asset.downloadURL.isFileURL {
            try FileManager.default.copyItem(at: asset.downloadURL, to: zip)
            return zip
        }
        var request = URLRequest(url: token == nil ? asset.downloadURL : asset.apiURL ?? asset.downloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (file, response) = try await URLSession.shared.download(for: request, delegate: DropAuthOnRedirect())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            guard try Self.sha256(of: file) == digest.dropFirst("sha256:".count).lowercased() else {
                throw UpdateError("The download doesn't match GitHub's checksum.")
            }
        }
        try FileManager.default.moveItem(at: file, to: zip)
        return zip
    }

    /// Unzips the release and checks it is Dash, at that version, with a valid signature.
    private func unpack(_ zip: URL, expecting version: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dash-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0 else { throw UpdateError("The zip didn't open.") }
        let app = folder.appending(path: "Dash.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The zip doesn't hold Dash.")
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError("The zip holds another version of Dash.")
        }
        guard try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError("The new Dash's signature isn't valid.")
        }
        return app
    }

    /// Starts the swap script, which outlives Dash: it waits for this process to exit.
    private func relaunch(replacing target: URL, with app: URL) throws {
        let script = """
            pid="$1"; new="$2"; target="$3"; old="$3.previous"
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            rm -rf "$old"
            if mv "$target" "$old"; then
              if mv "$new" "$target"; then rm -rf "$old"; else mv "$old" "$target"; fi
            fi
            xattr -dr com.apple.quarantine "$target" 2>/dev/null
            open "$target"
            """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, target.path]
        try process.run()
    }

    // MARK: - Helpers

    /// True when `version` is later than `current`, comparing dot-separated numbers.
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let parse = { (text: String) in text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parse(version), b = parse(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The GitHub CLI's token, for private repositories.
    nonisolated private static func ghToken() -> String? {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: gh)
        process.arguments = ["auth", "token"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let token = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !token.isEmpty ? token : nil
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// GitHub redirects asset downloads to storage that rejects the API token: drop it there.
private final class DropAuthOnRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var request = request
        if request.url?.host() != "api.github.com" { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        return request
    }
}
