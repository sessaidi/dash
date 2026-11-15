import DashKit
import DashKitTesting
import Foundation
import Testing
@testable import Dash

/// Repositories read through the GitHub or GitLab integration, without a checkout.
@MainActor
@Suite(.serialized)
struct RemoteRepositoryTests {
    @Test func parsesSpecsAndURLs() {
        #expect(RemoteRepository.parse("github:acme/api") == RemoteRepository(provider: .github, slug: "acme/api"))
        #expect(RemoteRepository.parse("github:acme/api@v2.1") == RemoteRepository(provider: .github, slug: "acme/api", ref: "v2.1"))
        #expect(RemoteRepository.parse("https://github.com/acme/api.git") == RemoteRepository(provider: .github, slug: "acme/api"))
        #expect(RemoteRepository.parse("https://github.com/acme/api/tree/main/src")?.slug == "acme/api")
        #expect(RemoteRepository.parse("gitlab:grp/sub/proj@main") == RemoteRepository(provider: .gitlab, slug: "grp/sub/proj", ref: "main"))
        #expect(RemoteRepository.parse("https://git.acme.io/grp/proj/-/tree/dev", gitlabHosts: ["git.acme.io"])?.slug == "grp/proj")
        #expect(RemoteRepository.parse("acme/api") == nil && RemoteRepository.parse("github:../etc") == nil)
    }

    /// A .tar.gz with one top folder, like GitHub's and GitLab's archives.
    static func archive() throws -> Data {
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-\(UUID().uuidString)")
        let top = root.appending(path: "acme-api-abc123")
        try FileManager.default.createDirectory(at: top.appending(path: "server"), withIntermediateDirectories: true)
        try "package server\n\nfunc Handle() {}\n".write(to: top.appending(path: "server/handler.go"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", root.appending(path: "a.tar.gz").path, "-C", root.path, "acme-api-abc123"]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: root.appending(path: "a.tar.gz"))
    }

    @Test func syncsThroughTheIntegrationAndIndexesTheMirror() async throws {
        let server = "gh-\(UUID().uuidString.prefix(8)).test"
        let tarball = try Self.archive()
        StubHTTP.serve(server) { request in
            switch request.url?.path() ?? "" {
            case "/repos/acme/api": (200, Data(#"{"default_branch":"main","html_url":"https://github.com/acme/api"}"#.utf8), [:])
            case "/repos/acme/api/commits/main": (200, Data(#"{"sha":"abc123"}"#.utf8), [:])
            case "/repos/acme/api/tarball/abc123": (200, tarball, [:])
            default: (404, Data(), [:])
            }
        }
        let github = TestIntegration(id: "github", baseURL: URL(string: "https://\(server)")!)
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "remote-\(UUID())")!, url: nil)
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "remote-\(UUID())")!),
                                     extensions: [knowledge, github], inMemory: true)
        knowledge.start(host: host)
        let remote = RemoteRepository(provider: .github, slug: "acme/api")
        try? FileManager.default.removeItem(at: remote.mirror)

        #expect(try await remote.sync(host: host) == .updated(sha: "abc123"))
        #expect(FileManager.default.fileExists(atPath: remote.mirror.appending(path: "server/handler.go").path))
        #expect(RemoteRepository.marker(in: remote.mirror)?.webURL == "https://github.com/acme/api")
        // Same commit: nothing downloaded again.
        #expect(try await remote.sync(host: host) == .unchanged)
        #expect(StubHTTP.requests(server).filter { $0.url?.path().contains("tarball") == true }.count == 1)

        let (url, cloned) = try await knowledge.resolveRepository("github:acme/api")
        #expect(url == remote.mirror && !cloned)
        #expect(KnowledgeExtension.remote(at: url.path) == RemoteRepository(provider: .github, slug: "acme/api", ref: "main"))
        let store = try #require(knowledge.store)
        _ = try await KnowledgeExtension.index(url.path, store: store, history: false)
        let repo = try #require(try await store.nodes(kind: "repo", repo: "repo:" + url.path, limit: 5).first)
        #expect(repo.name == "api" && repo.qualified == "acme/api" && repo.url == "https://github.com/acme/api")
        knowledge.removeRepository(url.path)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func needsTheIntegration() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "remote-\(UUID())")!), extensions: [], inMemory: true)
        await #expect(throws: ToolError.self) { try await RemoteRepository(provider: .gitlab, slug: "grp/proj").sync(host: host) }
    }
}

/// Watched repositories reach Knowledge through Dash's database.
@MainActor
@Suite(.serialized)
struct WatchedRepositoryTests {
    @Test func knowledgeFollowsWhatIntegrationsWatch() async throws {
        let server = "gh-\(UUID().uuidString.prefix(8)).test"
        let tarball = try RemoteRepositoryTests.archive()
        StubHTTP.serve(server) { request in
            switch request.url?.path() ?? "" {
            case "/repos/acme/web": (200, Data(#"{"default_branch":"main","html_url":"https://github.com/acme/web"}"#.utf8), [:])
            case "/repos/acme/web/commits/main": (200, Data(#"{"sha":"def456"}"#.utf8), [:])
            case "/repos/acme/web/tarball/def456": (200, tarball, [:])
            default: (404, Data(), [:])
            }
        }
        let github = TestIntegration(id: "github", baseURL: URL(string: "https://\(server)")!)
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "watched-\(UUID())")!, url: nil)
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "watched-\(UUID())")!),
                                     extensions: [knowledge, github], inMemory: true)
        knowledge.start(host: host)
        let mirror = RemoteRepository(provider: .github, slug: "acme/web").mirror
        try? FileManager.default.removeItem(at: mirror)

        WatchedRepositories.publish(["acme/web"], provider: "github", web: "https://github.com", in: host.synced)
        #expect(WatchedRepositories.all(in: host.synced) == [.init(provider: "github", slug: "acme/web", webURL: "https://github.com/acme/web")])
        await knowledge.followWatchedRepositories()
        #expect(knowledge.repositories == [mirror.standardizedFileURL.path])

        // Unwatched in the integration: dropped from the graph.
        WatchedRepositories.publish([], provider: "github", web: nil, in: host.synced)
        await knowledge.followWatchedRepositories()
        #expect(knowledge.repositories.isEmpty && knowledge.followed.isEmpty)
    }
}
