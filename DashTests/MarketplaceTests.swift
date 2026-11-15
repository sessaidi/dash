import CryptoKit
import DashKit
import Foundation
import Testing
@testable import Dash

@MainActor
struct MarketplaceTests {
    @Test func decodesFormat2RegistriesWithPlugins() throws {
        let json = """
        {"format": 2, "name": "Dash Extensions", "extensions": [
          {"id": "github", "name": "GitHub", "kind": "integration", "version": "1.0.0",
           "plugin": {"download": "dist/github-1.0.0.dashplugin.zip", "sha256": "ab", "minimumDashKit": "1.0.0", "provides": ["github"]}},
          {"id": "zoom", "name": "Zoom", "kind": "feature", "version": "1.0.0", "plugin": {"download": "dist/zoom-1.0.0.dashplugin.zip"}}
        ]}
        """
        let index = try JSONDecoder().decode(RegistryIndex.self, from: Data(json.utf8))
        #expect(index.extensions[0].plugin?.provides == ["github"])
        #expect(index.extensions[1].plugin?.sha256 == nil)
    }

    @Test func entriesTakeTheRegistryLabelUnlessTheyHaveTheirOwn() throws {
        let json = """
        {"format": 2, "name": "Work", "label": "Acme", "extensions": [
          {"id": "deploys", "name": "Deploys", "version": "1.0.0"},
          {"id": "jira", "name": "Jira", "version": "1.0.0", "label": "Community"}
        ]}
        """
        let index = try JSONDecoder().decode(RegistryIndex.self, from: Data(json.utf8))
        #expect(index.label(of: index.extensions[0]) == "Acme")
        #expect(index.label(of: index.extensions[1]) == "Community")
        // Installs from before labels still decode.
        let old = try JSONDecoder().decode(InstallRecord.self, from: Data(#"{"registry":"r","commit":"c","version":"1","installedAt":0}"#.utf8))
        #expect(old.label == nil)
        #expect(MarketplaceFeature.tone(ofLabel: "Community") == .success && MarketplaceFeature.tone(ofLabel: "Acme") == .accent)
    }

    @Test func localRegistriesAreFolderPaths() {
        let marketplace = MarketplaceFeature()
        let saved = marketplace.registriesText
        defer { marketplace.registriesText = saved }
        marketplace.registriesText = "sessaidi/dash-registry@main\n~/code/dash-registry\nnot a registry"
        #expect(marketplace.registries.count == 2)
        #expect(marketplace.registries[0] == .github(repo: "sessaidi/dash-registry", ref: "main"))
        if case .local(let url) = marketplace.registries[1] {
            #expect(url.path(percentEncoded: false).hasSuffix("/code/dash-registry/"))
        } else {
            Issue.record("expected a local registry")
        }
    }

    @Test func unpacksAZippedPluginAndReadsItsID() throws {
        // A minimal bundle: Info.plist with the plugin keys and an "executable".
        let work = FileManager.default.temporaryDirectory.appending(path: "dash-plugin-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: work) }
        let bundle = work.appending(path: "ExamplePlugin.dashplugin/Contents")
        try FileManager.default.createDirectory(at: bundle.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "ExamplePlugin", "CFBundleIdentifier": "dev.example.plugin",
                                   "CFBundlePackageType": "BNDL", DashPluginKeys.id: "example", DashPluginKeys.version: "2.1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appending(path: "Info.plist"))
        try Data("not really a binary".utf8).write(to: bundle.appending(path: "MacOS/ExamplePlugin"))
        try FileManager.default.createDirectory(at: bundle.appending(path: "Resources"), withIntermediateDirectories: true)
        try Data(#"{"name": "Example", "kind": "feature", "description": "Shows examples.", "requires": ["github", "nope"], "author": {"name": "Ada"}}"#.utf8)
            .write(to: bundle.appending(path: "Resources/plugin.json"))
        let zip = work.appending(path: "example.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", work.appending(path: "ExamplePlugin.dashplugin").path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        let unpacked = try PluginArchive.unpack(try Data(contentsOf: zip))
        defer { try? FileManager.default.removeItem(at: unpacked.deletingLastPathComponent().deletingLastPathComponent()) }
        let record = PluginLoader.inspect(unpacked, bundled: false)
        #expect(record.id == "example")
        #expect(record.version == "2.1.0")
        #expect(record.displayName == "Example" && record.info?.requires == ["github", "nope"])
        let details = try #require(record.info?.details(installed: ["github"]))
        #expect(details.first { $0.title == "Needs" }?.text == "github, nope (not installed)")
        #expect(details.first { $0.title == "By" }?.text == "Ada")
        #expect(record.sha256 == SHA256.hash(data: Data("not really a binary".utf8)).map { String(format: "%02x", $0) }.joined())
    }
}

@MainActor
struct RegistryParsingTests {
    typealias Registry = MarketplaceFeature.Registry

    @Test func parsesEveryKindOfRegistry() {
        #expect(Registry.parse("sessaidi/dash-registry") == .github(repo: "sessaidi/dash-registry", ref: "HEAD"))
        #expect(Registry.parse("https://github.com/sessaidi/dash-registry/tree/dev") == .github(repo: "sessaidi/dash-registry", ref: "dev"))
        #expect(Registry.parse("https://gitlab.example.com/platform/tools/dash-registry/-/tree/main")
                == .gitlab(host: "gitlab.example.com", project: "platform/tools/dash-registry", ref: "main"))
        #expect(Registry.parse("gitlab:gitlab.com/acme/dash@v2") == .gitlab(host: "gitlab.com", project: "acme/dash", ref: "v2"))
        #expect(Registry.parse("https://cdn.example.com/dash/registry.json") == .url(URL(string: "https://cdn.example.com/dash/registry.json")!))
        if case .local(let url)? = Registry.parse("~/code/dash-registry") { #expect(url.path.hasSuffix("/code/dash-registry")) } else { Issue.record("local") }
        // Saved lines read back as the same registry.
        for registry in [Registry.gitlab(host: "gitlab.com", project: "a/b/c", ref: "x"), .github(repo: "o/n", ref: "HEAD")] {
            #expect(Registry.parse(registry.line) == registry)
        }
        #expect(AddRegistrySheet.indexLocation(.gitlab(host: "gitlab.com", project: "a/b", ref: "HEAD")) == "gitlab.com/api/v4/projects/a%2Fb/repository/files/registry.json/raw")
    }
}

/// Loads every plugin the registry built (DASH_DIST=<registry>/dist), the way an install does.
@MainActor
struct BuiltPluginLoadingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_DIST"] != nil))
    func everyBuiltPluginLoads() throws {
        let dist = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DASH_DIST"]!)
        let zips = try FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".dashplugin.zip") }
        #expect(!zips.isEmpty)
        var ids = Set(ExtensionHost.builtInExtensions().map(\.id))
        for zip in zips.sorted(by: { $0.path < $1.path }) {
            let bundle = try PluginArchive.unpack(try Data(contentsOf: zip))
            defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent().deletingLastPathComponent()) }
            let record = PluginLoader.inspect(bundle, bundled: false)
            if case .failed(let reason) = record.state { Issue.record("\(zip.lastPathComponent): \(reason)"); continue }
            let (state, extensions) = PluginLoader.load(bundle, reserved: &ids)
            if case .loaded = state {
                print("LOADED \(zip.lastPathComponent): \(extensions.map(\.id))")
            } else {
                Issue.record("\(zip.lastPathComponent): \(state)")
            }
            #expect(!extensions.isEmpty, "\(zip.lastPathComponent)")
        }
    }

    @Test func dependenciesAreTransitiveOrderedAndEnforced() async throws {
        let json = """
        {"format": 2, "name": "Test", "extensions": [
          {"id": "wsx-test", "name": "Workspaces", "kind": "feature", "version": "1.0.0", "requires": ["agx-test", "git"], "plugin": {"download": "w.zip"}},
          {"id": "agx-test", "name": "Agents", "kind": "feature", "version": "1.0.0", "requires": ["atx-test"], "plugin": {"download": "a.zip"}},
          {"id": "atx-test", "name": "Atlassian", "kind": "integration", "version": "1.0.0", "plugin": {"download": "j.zip"}}
        ]}
        """
        let index = try JSONDecoder().decode(RegistryIndex.self, from: Data(json.utf8))
        let marketplace = MarketplaceFeature()
        marketplace.setCatalog(index, label: "test")
        let workspaces = try #require(index.extensions.first)
        // Requirements of requirements, each after what it needs; built-ins (git) count as present.
        #expect(marketplace.missingDependencies(of: workspaces).map(\.id) == ["atx-test", "agx-test"])
        await #expect(throws: ToolError("Workspaces needs Atlassian, Agents first.")) { try await marketplace.install(workspaces, from: "test") }
        // Nothing installed requires these, so removing is allowed (and a no-op here).
        #expect(marketplace.dependents(of: "agx-test").isEmpty)
    }
}
