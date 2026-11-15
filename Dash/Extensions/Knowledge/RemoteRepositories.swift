import DashKit
import Foundation

/// A repository the knowledge graph reads through the GitHub or GitLab integration, without a
/// local checkout: a snapshot of its default branch (or a ref) is downloaded with the
/// integration's own connection (its token never reaches Knowledge) into Dash's mirror folder,
/// then indexed like a local repository. A refresh downloads again only when the ref moved.
struct RemoteRepository: Codable, Hashable, Sendable {
    enum Provider: String, Codable, Sendable { case github, gitlab }

    let provider: Provider
    /// "owner/name" (GitHub) or "group/sub/project" (GitLab).
    let slug: String
    /// A branch or tag; nil follows the default branch.
    var ref: String?

    /// What a mirror records about itself (`.dash-remote.json` in its folder).
    struct Marker: Codable, Sendable {
        var provider: Provider
        var slug: String
        var ref: String
        var sha: String
        var webURL: String
        var syncedAt: Date
    }

    static let markerName = ".dash-remote.json"

    static var mirrorsRoot: URL {
        if NSClassFromString("XCTestCase") != nil { return FileManager.default.temporaryDirectory.appending(path: "dash-mirrors") }
        return URL.applicationSupportDirectory.appending(path: "Dash/Knowledge/Mirrors")
    }

    var mirror: URL {
        Self.mirrorsRoot.appending(path: provider.rawValue).appending(path: slug.replacingOccurrences(of: "/", with: "__"))
    }

    var label: String { "\(provider.rawValue):\(slug)" + (ref.map { "@\($0)" } ?? "") }

    /// `github:owner/name`, `gitlab:group/project@ref`, or a github.com / GitLab web URL.
    /// `gitlabHosts` are the GitLab instances the integration is set up for.
    static func parse(_ text: String, gitlabHosts: [String] = ["gitlab.com"]) -> RemoteRepository? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var ref: String?
        // A ref follows the last "@" after the last "/": github:acme/api@v2, gitlab:grp/proj@main.
        if let at = text.lastIndex(of: "@"), let slash = text.lastIndex(of: "/"), at > slash {
            ref = String(text[text.index(after: at)...])
            text = String(text[..<at])
        }
        func clean(_ slug: Substring) -> String? {
            var slug = String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if slug.hasSuffix(".git") { slug.removeLast(4) }
            if let tree = slug.range(of: "/-/") { slug = String(slug[..<tree.lowerBound]) }
            let parts = slug.split(separator: "/")
            // Names only: no "." or ".." segments that could climb out of the mirror folder.
            guard parts.count >= 2, parts.allSatisfy({ $0 != "." && $0 != ".." && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else { return nil }
            return slug
        }
        if text.hasPrefix("github:"), let slug = clean(text.dropFirst(7)), slug.split(separator: "/").count == 2 {
            return RemoteRepository(provider: .github, slug: slug, ref: ref)
        }
        if text.hasPrefix("gitlab:"), let slug = clean(text.dropFirst(7)) { return RemoteRepository(provider: .gitlab, slug: slug, ref: ref) }
        guard let url = URL(string: text), let host = url.host()?.lowercased() else { return nil }
        if host == "github.com" || host == "www.github.com" {
            let parts = url.path.split(separator: "/").prefix(2)
            guard let slug = clean(parts.joined(separator: "/")[...]) else { return nil }
            return RemoteRepository(provider: .github, slug: slug, ref: ref)
        }
        if gitlabHosts.contains(host) || host.contains("gitlab"), let slug = clean(url.path[...]) {
            return RemoteRepository(provider: .gitlab, slug: slug, ref: ref)
        }
        return nil
    }

    static func marker(in folder: URL) -> Marker? {
        guard let data = try? Data(contentsOf: folder.appending(path: markerName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Marker.self, from: data)
    }

    // MARK: Sync

    enum SyncResult: Sendable, Equatable { case unchanged, updated(sha: String) }

    /// Downloads the snapshot when the ref moved since the last sync.
    @MainActor
    func sync(host: any ExtensionContext) async throws -> SyncResult {
        let integration = provider.rawValue
        guard let connection = host.integration(integration)?.connection else {
            throw ToolError("Connect \(integration == "github" ? "GitHub" : "GitLab") in Settings to read \(slug) without a checkout.")
        }
        let service = provider == .github ? "GitHub" : "GitLab"
        let project = slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? slug
        let info = try await connection.get(provider == .github ? "/repos/\(slug)" : "/projects/\(project)", service: service)
        let branch = ref ?? info["default_branch"]?.string ?? "main"
        let webURL = info["html_url"]?.string ?? info["web_url"]?.string ?? ""
        let encodedRef = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? branch
        let commit = try await connection.get(provider == .github ? "/repos/\(slug)/commits/\(encodedRef)"
                                                                  : "/projects/\(project)/repository/commits/\(encodedRef)", service: service)
        guard let sha = commit["sha"]?.string ?? commit["id"]?.string else { throw ToolError("\(service) didn't say which commit \(branch) is at.") }
        if Self.marker(in: mirror)?.sha == sha { return .unchanged }

        let archivePath = provider == .github ? "/repos/\(slug)/tarball/\(sha)" : "/projects/\(project)/repository/archive.tar.gz?sha=\(sha)"
        guard let url = connection.url(archivePath) else { throw ToolError("Bad archive path for \(slug).") }
        let (data, response) = try await connection.send(URLRequest(url: url), service: service)
        guard (200..<300).contains(response.statusCode), !data.isEmpty else {
            throw ToolError("\(service) refused the archive of \(slug) (HTTP \(response.statusCode)).")
        }
        let marker = Marker(provider: provider, slug: slug, ref: branch, sha: sha, webURL: webURL, syncedAt: .now)
        try await Self.install(archive: data, into: mirror, marker: marker)
        return .updated(sha: sha)
    }

    /// Unpacks a .tar.gz next to the mirror, then swaps it in, so a failed download keeps the old one.
    nonisolated static func install(archive: Data, into mirror: URL, marker: Marker) async throws {
        try await Task.detached(priority: .utility) {
            let files = FileManager.default
            try files.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = mirror.deletingLastPathComponent().appending(path: ".\(mirror.lastPathComponent)-\(UUID().uuidString.prefix(8))")
            let tarball = staging.appendingPathExtension("tar.gz")
            defer { try? files.removeItem(at: tarball) }
            try archive.write(to: tarball)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            // Archives hold one top folder (owner-name-sha): drop it.
            process.arguments = ["-xzf", tarball.path, "-C", staging.path, "--strip-components", "1"]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? files.removeItem(at: staging)
                throw ToolError("Couldn't unpack the archive of \(marker.slug).")
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(marker).write(to: staging.appending(path: markerName))
            if files.fileExists(atPath: mirror.path) { try files.removeItem(at: mirror) }
            try files.moveItem(at: staging, to: mirror)
        }.value
    }
}
