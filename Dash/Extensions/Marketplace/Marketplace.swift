import DashKit
import DashKitUI
import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// `registry.json` at the root of a registry repository: the plugins it offers.
struct RegistryIndex: Codable, Equatable {
    var format: Int
    var name: String
    var extensions: [Entry]

    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var kind: ExtensionLayer?
        var version: String
        var description: String?
        var icon: String?
        var author: ExtensionAuthor?
        var requires: [String]?
        var optional: [String]?
        /// Path of its README in the registry.
        var readme: String?
        /// The `.dashplugin`, zipped in the repository.
        var plugin: Plugin?
        /// Swift extensions compiled into Dash are listed for discovery but can't be installed.
        var builtIn: Bool?
    }

    struct Plugin: Codable, Equatable {
        /// The zip's path inside the repository, e.g. "dist/github-1.0.0.dashplugin.zip".
        var download: String
        /// SHA-256 of the zip; the download is refused if it doesn't match.
        var sha256: String?
        var minimumDashKit: String?
        /// The extension ids (integrations and features) the plugin adds.
        var provides: [String]?
    }
}

/// Written when something is installed: where it came from.
struct InstallRecord: Codable, Equatable {
    var registry: String
    var commit: String
    var version: String
    var installedAt: Date
}

/// Installs `.dashplugin` bundles from git repositories used as registries ("marketplaces"):
/// each download is checked against the registry's SHA-256, approved, and loaded right away
/// (hot install). Updates and removals of a loaded plugin take effect at the next launch, since
/// code can't be unloaded. Reads go through the GitHub integration when one is connected
/// (private repos), anonymously otherwise; a registry can also be a local folder.
@MainActor
@Observable
final class MarketplaceFeature: DashExtension {
    let id = "marketplace"
    let name = "Marketplace"
    let systemImage = "bag"
    let metadata = ExtensionMetadata(version: "1.1.0", summary: "Install integrations and features from git registries.", category: .other, homepage: "https://github.com/sessaidi/dash")
    let optional = ["github"]

    /// "owner/name", "owner/name@ref", or a local folder path, one per line.
    var registriesText: String { didSet { DashDefaults.shared.set(registriesText, forKey: "marketplace.registries") } }
    private(set) var catalogs: [String: (index: RegistryIndex, commit: String)] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var isLoading = false
    /// A loaded plugin was updated or removed: that takes effect after a relaunch.
    private(set) var needsRelaunch = false

    @ObservationIgnored private weak var host: (any ExtensionContext)?

    /// The official registry, added on first launch (with your local clone of it, when there is one).
    static let defaultRegistry = "sessaidi/dash-registry"

    init() {
        if let saved = DashDefaults.shared.string(forKey: "marketplace.registries"), !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            registriesText = saved
        } else {
            let local = ("~/code/dash-registry" as NSString).expandingTildeInPath
            let lines = [Self.defaultRegistry] + (FileManager.default.fileExists(atPath: local + "/registry.json") ? ["~/code/dash-registry"] : [])
            registriesText = lines.joined(separator: "\n")
        }
    }

    func add(_ registry: Registry) {
        guard !registries.contains(registry) else { return }
        registriesText = (registriesText.isEmpty ? "" : registriesText + "\n") + registry.line
        Task { await refresh() }
    }

    func remove(_ registry: Registry) {
        registriesText = registries.filter { $0 != registry }.map(\.line).joined(separator: "\n")
        catalogs[registry.label] = nil
        errors[registry.label] = nil
    }

    func settingsView() -> AnyView { AnyView(MarketplaceView(marketplace: self)) }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await refresh() }
    }

    enum Registry: Hashable {
        case github(repo: String, ref: String)
        /// A GitLab project (gitlab.com or self-managed): `group/subgroup/project`.
        case gitlab(host: String, project: String, ref: String)
        case local(URL)
        /// A registry.json anywhere over HTTPS; plugin zips are next to it.
        case url(URL)

        var label: String {
            switch self {
            case .github(let repo, let ref): ref == "HEAD" ? repo : "\(repo)@\(ref)"
            case .gitlab(let host, let project, let ref): "\(host)/\(project)" + (ref == "HEAD" ? "" : "@\(ref)")
            case .local(let url): url.path(percentEncoded: false)
            case .url(let url): url.absoluteString
            }
        }

        /// How it's saved (one per line).
        var line: String {
            switch self {
            case .github: label
            case .gitlab(let host, let project, let ref): "gitlab:\(host)/\(project)" + (ref == "HEAD" ? "" : "@\(ref)")
            case .local(let url): (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            case .url(let url): url.absoluteString
            }
        }

        var kind: String {
            switch self {
            case .github: "GitHub"
            case .gitlab: "GitLab"
            case .local: "Local folder"
            case .url: "URL"
            }
        }

        var systemImage: String {
            switch self {
            case .github, .gitlab: "chevron.left.forwardslash.chevron.right"
            case .local: "folder"
            case .url: "link"
            }
        }

        /// Parses a saved line, or anything pasted: owner/name[@ref], a github.com or GitLab
        /// URL (…/tree/<branch>), gitlab:host/group/project[@ref], a registry.json URL, a path.
        static func parse(_ text: String) -> Registry? {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("/") || line.hasPrefix("~") {
                return .local(URL(fileURLWithPath: (line as NSString).expandingTildeInPath, isDirectory: true))
            }
            func split(_ value: String) -> (String, String) {
                let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
                return (parts[0], parts.count > 1 ? parts[1] : "HEAD")
            }
            if line.hasPrefix("gitlab:") {
                let (path, ref) = split(String(line.dropFirst(7)))
                let segments = path.split(separator: "/").map(String.init)
                guard segments.count >= 3 else { return nil }
                return .gitlab(host: segments[0], project: segments.dropFirst().joined(separator: "/"), ref: ref)
            }
            if let url = URL(string: line), let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host() {
                if url.lastPathComponent.hasSuffix(".json") { return .url(url) }
                var segments = url.pathComponents.filter { $0 != "/" }
                var ref = "HEAD"
                // …/tree/<branch> (GitHub) or …/-/tree/<branch> (GitLab)
                if let tree = segments.firstIndex(of: "tree"), tree + 1 < segments.count {
                    ref = segments[(tree + 1)...].joined(separator: "/")
                    segments = Array(segments[..<tree])
                }
                if segments.last == "-" { segments.removeLast() }
                if host == "github.com", segments.count >= 2 { return .github(repo: "\(segments[0])/\(segments[1])".replacingOccurrences(of: ".git", with: ""), ref: ref) }
                if segments.count >= 2 { return .gitlab(host: host, project: segments.joined(separator: "/").replacingOccurrences(of: ".git", with: ""), ref: ref) }
                return nil
            }
            let (repo, ref) = split(line)
            guard repo.split(separator: "/").count == 2 else { return nil }
            return .github(repo: repo, ref: ref)
        }
    }

    var registries: [Registry] {
        registriesText.split(whereSeparator: \.isNewline).compactMap { Registry.parse(String($0)) }
    }

    /// GitLab: the GitLab integration's connection for its own instance (private projects), else anonymous.
    private func gitlab(_ host: String) -> GitLabRegistryClient {
        let connection = self.host?.integration("gitlab")?.connection
        let mine = connection.map { $0.baseURL.host() == host } ?? false
        return GitLabRegistryClient(host: host, connection: mine ? connection : nil)
    }

    private var client: RegistryClient {
        RegistryClient(connection: host?.integration("github")?.connection
            ?? IntegrationConnection(baseURL: URL(string: "https://api.github.com")!))
    }

    /// Reads a file from a registry at a pinned commit (local folders: the file as it is now).
    private func read(_ path: String, from registry: Registry, commit: String) async throws -> Data {
        switch registry {
        case .github(let repo, _): return try await client.file(repo, path: path, ref: commit)
        case .gitlab(let host, let project, _): return try await gitlab(host).file(project, path: path, ref: commit)
        case .url(let index):
            let url = index.deletingLastPathComponent().appending(path: path)
            guard path == "registry.json" || url.absoluteString.hasPrefix(index.deletingLastPathComponent().absoluteString) else { throw ToolError("\(path) is outside the registry.") }
            let (data, _) = try await HTTP.send(URLRequest(url: path == "registry.json" ? index : url), service: "Registry")
            return data
        case .local(let folder):
            let url = folder.appending(path: path)
            guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) else { throw ToolError("\(path) is outside the registry.") }
            return try Data(contentsOf: url)
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        for registry in registries {
            do {
                let commit: String
                switch registry {
                case .github(let repo, let ref): commit = try await client.resolve(repo, ref: ref)
                case .gitlab(let host, let project, let ref): commit = try await gitlab(host).resolve(project, ref: ref)
                case .local: commit = "local"
                case .url: commit = "url"
                }
                let index = try JSONDecoder().decode(RegistryIndex.self, from: try await read("registry.json", from: registry, commit: commit))
                guard index.format >= 1 else { throw ToolError("registry format \(index.format) is not supported") }
                catalogs[registry.label] = (index, commit)
                errors[registry.label] = nil
            } catch {
                errors[registry.label] = error.localizedDescription
            }
        }
        for label in catalogs.keys where !registries.map(\.label).contains(label) { catalogs[label] = nil }
    }

    // MARK: Install state

    static func pluginURL(for id: String) -> URL { PluginLoader.userFolder.appending(path: "\(id).dashplugin") }
    private static let pluginInstallsKey = "marketplace.pluginInstalls"

    private static var pluginInstalls: [String: InstallRecord] {
        get {
            guard let data = DashDefaults.shared.data(forKey: pluginInstallsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: InstallRecord].self, from: data)) ?? [:]
        }
        set { DashDefaults.shared.set(try? JSONEncoder().encode(newValue), forKey: pluginInstallsKey) }
    }

    func installed(_ id: String) -> InstallRecord? {
        guard let record = Self.pluginInstalls[id], FileManager.default.fileExists(atPath: Self.pluginURL(for: id).path) else { return nil }
        return record
    }

    /// Installs (or updates) a plugin from the registry's pinned commit.
    /// An entry's README from its registry (nil when it has none).
    func readme(_ entry: RegistryIndex.Entry, from registryLabel: String) async -> String? {
        guard let path = entry.readme, let registry = registries.first(where: { $0.label == registryLabel }),
              let catalog = catalogs[registryLabel], let data = try? await read(path, from: registry, commit: catalog.commit) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A dependency a feature needs that isn't installed, and where to get it.
    struct MissingDependency: Identifiable {
        let id: String
        let entry: RegistryIndex.Entry?
        let registry: String?
    }

    /// What an entry requires that isn't installed (nor built in), with its registry entry if one has it.
    func missingDependencies(of entry: RegistryIndex.Entry) -> [MissingDependency] {
        let present = Set(host?.extensions.map(\.id) ?? [])
        return (entry.requires ?? []).filter { !present.contains($0) && installed($0) == nil }.map { id in
            let found = catalogs.lazy.compactMap { label, catalog in catalog.index.extensions.first { $0.id == id }.map { ($0, label) } }.first
            return MissingDependency(id: id, entry: found?.0, registry: found?.1)
        }
    }

    func install(_ entry: RegistryIndex.Entry, from registryLabel: String) async throws {
        guard entry.builtIn != true else { throw ToolError("\(entry.name) is built into Dash; nothing to install.") }
        guard let registry = registries.first(where: { $0.label == registryLabel }), let catalog = catalogs[registryLabel] else {
            throw ToolError("Unknown registry \(registryLabel).")
        }
        // A local folder changes under us (rebuilt zips): read its index again first.
        if case .local = registry { await refresh() }
        let current = catalogs[registryLabel]?.index.extensions.first { $0.id == entry.id } ?? entry
        guard let plugin = current.plugin else { throw ToolError("\(entry.name) has no plugin to install.") }
        do {
            try await installPlugin(current, plugin, from: registry, commit: catalogs[registryLabel]?.commit ?? catalog.commit)
        } catch {
            // The index may be stale (a newer version replaced the zip): refresh and try once more.
            await refresh()
            guard let fresh = catalogs[registryLabel], let latest = fresh.index.extensions.first(where: { $0.id == entry.id }),
                  let latestPlugin = latest.plugin, latest.version != current.version || fresh.commit != catalog.commit else { throw error }
            try await installPlugin(latest, latestPlugin, from: registry, commit: fresh.commit)
        }
    }

    /// Downloads the plugin zip, checks its SHA-256 against the registry, unpacks it into the
    /// user's Plugins folder and approves that exact build (installing is the user's consent).
    private func installPlugin(_ entry: RegistryIndex.Entry, _ plugin: RegistryIndex.Plugin, from registry: Registry, commit: String) async throws {
        guard let expected = plugin.sha256?.lowercased(), !expected.isEmpty else {
            throw ToolError("\(entry.name) has no SHA-256 in the registry; refusing to install an unverified plugin.")
        }
        if let minimum = plugin.minimumDashKit, ExtensionMetadata.compare(DashKitInfo.version, minimum) == .orderedAscending {
            throw ToolError("\(entry.name) needs DashKit \(minimum); this Dash has \(DashKitInfo.version). Update Dash first.")
        }
        let zip = try await read(plugin.download, from: registry, commit: commit)
        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw ToolError("\(entry.name): the download's SHA-256 (\(actual.prefix(12))…) doesn't match the registry (\(expected.prefix(12))…). Not installed.")
        }
        let bundle = try PluginArchive.unpack(zip)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let record = PluginLoader.inspect(bundle, bundled: false)
        guard record.id == entry.id else { throw ToolError("The archive holds plugin \(record.id), not \(entry.id).") }
        if case .failed(let reason) = record.state { throw ToolError("\(entry.name): \(reason)") }

        let destination = Self.pluginURL(for: entry.id)
        let wasLoaded = (host as? ExtensionHost)?.plugins.contains { $0.id == entry.id && $0.isLoaded } == true
        try FileManager.default.createDirectory(at: PluginLoader.userFolder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: bundle, to: destination)
        PluginLoader.approve(PluginLoader.inspect(destination, bundled: false))
        Self.pluginInstalls[entry.id] = InstallRecord(registry: registry.label, commit: commit, version: entry.version, installedAt: .now)
        if wasLoaded {
            // The old build stays in memory until Dash relaunches.
            needsRelaunch = true
            host?.activity.emit("marketplace.updated", source: id, title: "Updated \(entry.name) to \(entry.version)",
                                detail: "Relaunch Dash to switch to it.", importance: .notable)
        } else {
            HotPlugins.shared.load(destination)
            host?.activity.emit("marketplace.installed", source: id, title: "Installed \(entry.name) \(entry.version)", importance: .notable)
        }
    }

    /// Removes a plugin. A loaded one stops now (background work, tools, widgets go quiet);
    /// its code leaves memory at the next launch.
    func uninstall(_ id: String) {
        let host = host as? ExtensionHost
        if let record = host?.plugins.first(where: { $0.id == id }), case .loaded(let ids) = record.state {
            for item in host?.extensions ?? [] where ids.contains(item.id) { host?.setEnabled(item, false) }
            needsRelaunch = true
        }
        try? FileManager.default.removeItem(at: Self.pluginURL(for: id))
        PluginLoader.revoke(id)
        Self.pluginInstalls[id] = nil
    }

    /// Starts a fresh Dash and quits this one, so installed plugins load.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Claude tools

    private func describe(_ entry: RegistryIndex.Entry, registry: String) -> JSONValue {
        let requires: [JSONValue] = (entry.requires ?? []).map { .string($0) }
        let installedVersion: JSONValue = installed(entry.id).map { .string($0.version) } ?? .null
        return [
            "id": .string(entry.id), "name": .string(entry.name), "kind": .string((entry.kind ?? .feature).rawValue),
            "version": .string(entry.version), "description": .string(entry.description ?? ""), "registry": .string(registry),
            "author": .string(entry.author?.name ?? ""), "requires": .array(requires), "built_in": .bool(entry.builtIn == true), "installed_version": installedVersion,
        ]
    }

    private struct InstallInput: Decodable { let id: String }

    var tools: [ClaudeTool] {
        [
            ClaudeTool(name: "marketplace_list", description: "List extensions (integrations and features) available in the configured registries, and which are installed.") { [weak self] _ in
                guard let self else { return [] }
                var items: [JSONValue] = []
                for (label, catalog) in catalogs {
                    for entry in catalog.index.extensions { items.append(describe(entry, registry: label)) }
                }
                return .array(items)
            },
            ClaudeTool(
                name: "marketplace_install",
                description: "Install or update an extension from a registry. Its own permission prompt follows.",
                properties: ["id": JSONSchema.string("Extension id from marketplace_list.")], required: ["id"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let id = try input.toolInput(InstallInput.self).id
                guard let (label, entry) = catalogs.lazy.compactMap({ label, catalog in catalog.index.extensions.first { $0.id == id }.map { (label, $0) } }).first else {
                    throw ToolError("No extension \(id) in the registries.")
                }
                try await install(entry, from: label)
                return .string("installed \(entry.name) \(entry.version)")
            },
        ]
    }
}

private struct MarketplaceView: View {
    @Bindable var marketplace: MarketplaceFeature
    @State private var error: String?
    @State private var working: String?
    @State private var adding: AddRegistrySheet.Kind?
    /// A plugin whose requirements are missing, waiting for the user's decision before installing.
    @State private var needs: PendingInstall?
    /// The entry whose page is open.
    @State private var details: PendingInstall?

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a folder with a registry.json (e.g. your clone of the registry)."
        if panel.runModal() == .OK, let url = panel.url { marketplace.add(.local(url)) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(marketplace.registries, id: \.self) { registry in
                    HStack {
                        Image(systemName: registry.systemImage).foregroundStyle(.tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(registry.label).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                if registry.line == MarketplaceFeature.defaultRegistry { Badge("Default", tone: .info) }
                            }
                            if let error = marketplace.errors[registry.label] {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                            } else if let catalog = marketplace.catalogs[registry.label] {
                                Text("\(registry.kind) · \(catalog.index.extensions.count) plugins").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(registry.kind).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { marketplace.remove(registry) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add Registry", systemImage: "plus") {
                        Button("GitHub Repository…", systemImage: "chevron.left.forwardslash.chevron.right") { adding = .github }
                        Button("GitLab Project…", systemImage: "chevron.left.forwardslash.chevron.right") { adding = .gitlab }
                        Button("Local Folder…", systemImage: "folder") { chooseFolder() }
                        Button("registry.json URL…", systemImage: "link") { adding = .url }
                        if !marketplace.registries.contains(where: { $0.line == MarketplaceFeature.defaultRegistry }) {
                            Divider()
                            Button("Dash Default Registry") { marketplace.add(.github(repo: MarketplaceFeature.defaultRegistry, ref: "HEAD")) }
                        }
                    }
                    .fixedSize()
                    if marketplace.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await marketplace.refresh() } }
                }
            } header: {
                Text("Registries")
            } footer: {
                Text("A registry is a repository or folder with a registry.json and plugin zips. Private GitHub or GitLab ones use your GitHub or GitLab integration.")
            }
            if marketplace.needsRelaunch {
                Section {
                    HStack {
                        Label("A loaded plugin was updated or removed. Relaunch Dash to finish.", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        Button("Relaunch Now") { marketplace.relaunch() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            ForEach(marketplace.errors.sorted(by: { $0.key < $1.key }), id: \.key) { label, message in
                Text("\(label): \(message)").foregroundStyle(.red).font(.callout)
            }
            ForEach(marketplace.catalogs.keys.sorted(), id: \.self) { label in
                if let catalog = marketplace.catalogs[label] {
                    Section("\(catalog.index.name) · \(label) @ \(catalog.commit.prefix(7))") {
                        ForEach(catalog.index.extensions) { entry in row(entry, label: label) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .sheet(item: $adding) { kind in AddRegistrySheet(kind: kind) { marketplace.add($0) } }
        .sheet(item: $needs) { pending in DependenciesSheet(marketplace: marketplace, entry: pending.entry, registry: pending.registry) }
        .sheet(item: $details) { pending in
            PluginDetailSheet(marketplace: marketplace, entry: pending.entry, registry: pending.registry) {
                details = nil
                if !marketplace.missingDependencies(of: pending.entry).isEmpty { needs = pending } else {
                    Task { try? await marketplace.install(pending.entry, from: pending.registry) }
                }
            }
        }
    }

    private func row(_ entry: RegistryIndex.Entry, label: String) -> some View {
        let installed = marketplace.installed(entry.id)
        return HStack(alignment: .top) {
            Image(systemName: entry.icon ?? "puzzlepiece.extension").frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).bold()
                    Text((entry.kind ?? .feature).rawValue).font(.caption2).padding(.horizontal, 5).background(.quaternary, in: .capsule)
                    Text(entry.version).font(.caption).foregroundStyle(.secondary)
                    if entry.plugin != nil {
                        Text("plugin").font(.caption2).padding(.horizontal, 5).background(.tint.opacity(0.18), in: .capsule)
                    }
                }
                if let description = entry.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                if let author = entry.author { Text("by \(author.name)").font(.caption2).foregroundStyle(.secondary) }
                if let requires = entry.requires, !requires.isEmpty {
                    Text("Requires \(requires.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
            .onTapGesture { details = PendingInstall(entry: entry, registry: label) }
            .help("Show details")
            Spacer()
            if entry.builtIn == true {
                Text("Built in").foregroundStyle(.secondary)
            } else if working == entry.id {
                ProgressView().controlSize(.small)
            } else {
                if installed != nil {
                    Button("Remove") { marketplace.uninstall(entry.id) }
                }
                Button("Details") { details = PendingInstall(entry: entry, registry: label) }
                if installed?.version != entry.version {
                    Button(installed == nil ? "Install" : "Update") {
                        working = entry.id
                        error = nil
                        Task {
                            do {
                                // Missing requirements: ask first, install nothing yet.
                                if !marketplace.missingDependencies(of: entry).isEmpty {
                                    needs = PendingInstall(entry: entry, registry: label)
                                } else {
                                    try await marketplace.install(entry, from: label)
                                }
                            } catch {
                                self.error = error.localizedDescription
                            }
                            working = nil
                        }
                    }
                }
            }
        }
    }
}

/// The two GitHub reads a registry needs: resolve a ref to a commit, read a file at it.
/// GitLab's files and commits API (gitlab.com or a self-managed instance).
struct GitLabRegistryClient: Sendable {
    let host: String
    let connection: IntegrationConnection?

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: "https://\(host)/api/v4\(path)") else { throw ToolError("Bad GitLab path \(path)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        if let connection { return try await connection.send(request, service: "GitLab").0 }
        return try await HTTP.send(request, service: "GitLab").0
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
    }

    func resolve(_ project: String, ref: String) async throws -> String {
        let path = ref == "HEAD" ? "/projects/\(Self.encode(project))" : "/projects/\(Self.encode(project))/repository/commits/\(Self.encode(ref))"
        let json = try JSONValue.parse(String(decoding: try await get(path), as: UTF8.self))
        if ref == "HEAD", let branch = json["default_branch"]?.string { return try await resolve(project, ref: branch) }
        guard let sha = json["id"]?.string else { throw ToolError("Unknown ref \(ref) in \(project).") }
        return sha
    }

    func file(_ project: String, path: String, ref: String) async throws -> Data {
        try await get("/projects/\(Self.encode(project))/repository/files/\(Self.encode(path))/raw?ref=\(ref)")
    }
}

struct RegistryClient: Sendable {
    let connection: IntegrationConnection

    private func get(_ path: String, accept: String) async throws -> Data {
        guard let url = connection.url(path) else { throw ToolError("Bad GitHub path \(path)") }
        var request = try HTTP.request(url, headers: ["Accept": accept, "X-GitHub-Api-Version": "2022-11-28"])
        request.timeoutInterval = 120
        return try await connection.send(request, service: "GitHub").0
    }

    /// A file's raw bytes (works for binaries up to 100 MB, unlike the JSON contents API).
    func file(_ repo: String, path: String, ref: String) async throws -> Data {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return try await get("/repos/\(repo)/contents/\(encoded)?ref=\(ref)", accept: "application/vnd.github.raw")
    }

    /// The commit SHA a branch, tag or SHA points to.
    func resolve(_ repo: String, ref: String) async throws -> String {
        let json = try JSONValue.parse(String(decoding: try await get("/repos/\(repo)/commits/\(ref)", accept: "application/vnd.github+json"), as: UTF8.self))
        guard let sha = json["sha"]?.string else { throw ToolError("Unknown ref \(ref) in \(repo).") }
        return sha
    }
}

/// Unzips a downloaded plugin archive with ditto (keeps the bundle's signature and symlinks).
enum PluginArchive {
    /// Returns the `.dashplugin` inside a fresh temporary folder (the caller removes the folder).
    static func unpack(_ zip: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dash-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appending(path: "plugin.zip")
        try zip.write(to: archive)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.appending(path: "out").path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError("Couldn't unpack the plugin archive (ditto exited \(process.terminationStatus)).") }
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder.appending(path: "out"), includingPropertiesForKeys: nil)) ?? []
        guard let bundle = contents.first(where: { $0.pathExtension == "dashplugin" }) else { throw ToolError("The archive has no .dashplugin.") }
        return bundle
    }
}


/// Adds a GitHub repository, a GitLab project or a registry.json URL. Pasting a full URL works
/// too (github.com/owner/name/tree/branch, gitlab.example.com/group/project).
struct AddRegistrySheet: View {
    enum Kind: String, Identifiable { case github, gitlab, url; var id: String { rawValue } }

    let kind: Kind
    let onAdd: (MarketplaceFeature.Registry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var host = "gitlab.com"
    @State private var branch = ""

    private var registry: MarketplaceFeature.Registry? {
        let ref = branch.trimmingCharacters(in: .whitespaces).isEmpty ? "HEAD" : branch.trimmingCharacters(in: .whitespaces)
        let text = repository.trimmingCharacters(in: .whitespaces)
        if text.contains("://") { return MarketplaceFeature.Registry.parse(text) }
        switch kind {
        case .github: return text.split(separator: "/").count == 2 ? .github(repo: text, ref: ref) : nil
        case .gitlab: return text.split(separator: "/").count >= 2 ? .gitlab(host: host.trimmingCharacters(in: .whitespaces), project: text, ref: ref) : nil
        case .url: return URL(string: text).map { .url($0) }
        }
    }

    var body: some View {
        Form {
            switch kind {
            case .github:
                TextField("Repository", text: $repository, prompt: Text("owner/name, or its github.com URL"))
                TextField("Branch or tag", text: $branch, prompt: Text("default branch"))
            case .gitlab:
                TextField("Instance", text: $host, prompt: Text("gitlab.com"))
                TextField("Project", text: $repository, prompt: Text("group/subgroup/project, or its URL"))
                TextField("Branch or tag", text: $branch, prompt: Text("default branch"))
            case .url:
                TextField("registry.json URL", text: $repository, prompt: Text("https://example.com/dash/registry.json"))
            }
            if let registry {
                LabeledContent("Reads", value: Self.indexLocation(registry)).font(.caption.monospaced())
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let registry { onAdd(registry) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(registry == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    /// Where registry.json is fetched from, shown so the user can check it.
    static func indexLocation(_ registry: MarketplaceFeature.Registry) -> String {
        switch registry {
        case .github(let repo, let ref): "api.github.com/repos/\(repo)/contents/registry.json" + (ref == "HEAD" ? "" : "?ref=\(ref)")
        case .gitlab(let host, let project, let ref):
            "\(host)/api/v4/projects/\(GitLabRegistryClient.encode(project))/repository/files/registry.json/raw" + (ref == "HEAD" ? "" : "?ref=\(ref)")
        case .local(let url): url.appending(path: "registry.json").path
        case .url(let url): url.absoluteString
        }
    }
}


struct PendingInstall: Identifiable {
    let entry: RegistryIndex.Entry
    let registry: String
    var id: String { entry.id }
}

/// Before installing a plugin whose requirements are missing: what it needs, each installable
/// from here. Nothing is installed until the user chooses; Cancel installs nothing.
struct DependenciesSheet: View {
    let marketplace: MarketplaceFeature
    let entry: RegistryIndex.Entry
    let registry: String
    @Environment(\.dismiss) private var dismiss
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        let missing = marketplace.missingDependencies(of: entry)
        let installable = missing.allSatisfy { $0.entry != nil }
        VStack(alignment: .leading, spacing: 14) {
            Label("\(entry.name) needs more", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold()).foregroundStyle(.orange)
            Text(missing.isEmpty ? "Everything it needs is installed." : "It won't work without these. Install them first, or cancel.")
                .foregroundStyle(.secondary)
            ForEach(missing) { dependency in
                HStack {
                    Image(systemName: dependency.entry?.icon ?? "puzzlepiece.extension").frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dependency.entry?.name ?? dependency.id).bold()
                        Text(dependency.entry?.description ?? "Not found in your registries.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if working == dependency.id {
                        ProgressView().controlSize(.small)
                    } else if let found = dependency.entry, let source = dependency.registry {
                        Button("Install") { run(dependency.id) { try await marketplace.install(found, from: source) } }
                            .disabled(working != nil)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Integrations need connecting once installed: Settings › Plugins.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working != nil)
                if missing.isEmpty {
                    Button("Install \(entry.name)") { run(entry.id) { try await marketplace.install(entry, from: registry); dismiss() } }
                        .keyboardShortcut(.defaultAction).disabled(working != nil)
                } else {
                    Button("Install All") {
                        run("all") {
                            for dependency in missing {
                                if let found = dependency.entry, let source = dependency.registry { try await marketplace.install(found, from: source) }
                            }
                            try await marketplace.install(entry, from: registry)
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working != nil || !installable)
                    .help(installable ? "Installs the requirements, then \(entry.name)" : "Some requirements aren't in your registries")
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func run(_ id: String, _ action: @escaping @MainActor () async throws -> Void) {
        working = id
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            working = nil
        }
    }
}

/// A Marketplace entry's page: what it is, what it needs, and its README.
struct PluginDetailSheet: View {
    let marketplace: MarketplaceFeature
    let entry: RegistryIndex.Entry
    let registry: String
    let onInstall: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ExtensionHost.self) private var host
    @State private var readme: String?
    @State private var loaded = false

    var body: some View {
        let installed = marketplace.installed(entry.id)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: entry.icon ?? "puzzlepiece.extension").font(.system(size: 30)).foregroundStyle(.tint)
                    .frame(width: 56, height: 56).background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.title2.bold())
                        Badge((entry.kind ?? .feature).rawValue, tone: .info)
                        Text(entry.version).font(.callout).foregroundStyle(.secondary)
                    }
                    if let author = entry.author { Text("by \(author.name)").font(.callout).foregroundStyle(.secondary) }
                    if let description = entry.description { Text(description) }
                    requirements("Requires", entry.requires ?? [])
                    requirements("Uses when installed", entry.optional ?? [])
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if let installed {
                        Text("Installed \(installed.version)").font(.caption).foregroundStyle(.green)
                    }
                    if installed?.version != entry.version, entry.plugin != nil {
                        Button(installed == nil ? "Install" : "Update to \(entry.version)", action: onInstall).buttonStyle(.borderedProminent)
                    }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .background(.background)
            .zIndex(1)
            Divider()
            ScrollView {
                Group {
                    if let readme {
                        NoteRenderer(source: readme, noteTitle: entry.name, depth: 1)
                    } else if loaded {
                        Text("No README in the registry for this plugin.").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            // Keep the README from scrolling up under the header.
            .clipped()
        }
        .frame(width: 760, height: 680)
        .task {
            readme = await marketplace.readme(entry, from: registry)
            loaded = true
        }
    }

    @ViewBuilder
    private func requirements(_ title: String, _ ids: [String]) -> some View {
        if !ids.isEmpty {
            HStack(spacing: 6) {
                Text(title + ":").font(.caption).foregroundStyle(.secondary)
                ForEach(ids, id: \.self) { id in
                    let present = host.extensions.contains { $0.id == id } || marketplace.installed(id) != nil
                    Label(id, systemImage: present ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption).foregroundStyle(present ? .green : .orange)
                }
            }
        }
    }
}
