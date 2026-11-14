import CryptoKit
import DashKit
import DashKitUI
import Foundation
import Security

/// A `.dashplugin` bundle Dash found.
struct PluginRecord: Identifiable, Hashable {
    enum State: Hashable {
        case loaded(extensionIDs: [String])
        /// Found in the user's Plugins folder and not approved for this exact build.
        case needsApproval
        case failed(String)
    }

    let id: String
    let version: String
    let url: URL
    /// Shipped inside Dash.app (first-party, trusted with the app).
    let bundled: Bool
    let sha256: String
    /// "Team ABCDE12345", "ad-hoc signed" or "unsigned".
    let signature: String
    var state: State
    /// What the bundle says about itself (`Contents/Resources/plugin.json`), if it says anything.
    var info: PluginInfo?

    var displayName: String { info?.name ?? id }
}

/// `plugin.json` inside a bundle: shown before the plugin is loaded, so the user knows what
/// they're approving.
struct PluginInfo: Codable, Hashable {
    struct Author: Codable, Hashable {
        var name: String
        var url: String?
        var email: String?
    }

    var name: String
    var kind: String?
    var icon: String?
    var description: String?
    var requires: [String]?
    var provides: [String]?
    var author: Author?

    /// The lines of the approval prompt that describe the plugin.
    func details(installed: Set<String>) -> [PermissionDetail] {
        var details: [PermissionDetail] = []
        if let description { details.append(.init(title: "What it does", text: description)) }
        if let kind { details.append(.init(title: "Kind", text: kind.capitalized)) }
        if let requires, !requires.isEmpty {
            let text = requires.map { installed.contains($0) ? $0 : "\($0) (not installed)" }.joined(separator: ", ")
            details.append(.init(title: "Needs", text: text))
        }
        if let author {
            details.append(.init(title: "By", text: [author.name, author.email, author.url].compactMap { $0 }.joined(separator: " · ")))
        }
        return details
    }
}

/// Finds and loads plugins: at launch before the store opens, and later on the fly (hot install).
///
/// - `Dash.app/Contents/PlugIns/*.dashplugin` load automatically.
/// - `~/Library/Application Support/Dash/Plugins/*.dashplugin` load only once approved;
///   approval is pinned to the executable's SHA-256, so a changed binary needs approving again.
@MainActor
enum PluginLoader {
    /// ~/Library/Application Support/Dash/Plugins
    static var userFolder: URL {
        let support = (try? ExtensionHost.storeURL().deletingLastPathComponent())
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Dash")
        return support.appending(path: "Plugins", directoryHint: .isDirectory)
    }
    static var bundledFolder: URL? { Bundle.main.builtInPlugInsURL }

    private static let approvalsKey = "dash.approvedPlugins"

    static var approvals: [String: String] {
        get { DashDefaults.shared.dictionary(forKey: approvalsKey) as? [String: String] ?? [:] }
        set { DashDefaults.shared.set(newValue, forKey: approvalsKey) }
    }

    static func approve(_ record: PluginRecord) {
        approvals[record.id] = record.sha256
    }

    static func revoke(_ id: String) {
        approvals[id] = nil
    }

    /// Loads what it can; returns every plugin found and the extensions they provide.
    static func loadAll(reserved: Set<String>) -> (records: [PluginRecord], extensions: [any DashExtension]) {
        var records: [PluginRecord] = []
        var extensions: [any DashExtension] = []
        var ids = reserved
        let bundled = bundledFolder.map { (folder: $0, bundled: true) }
        try? FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        for (folder, isBundled) in [bundled, (userFolder, false)].compactMap({ $0 }) {
            let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "dashplugin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in urls {
                var record = inspect(url, bundled: isBundled)
                if records.contains(where: { $0.id == record.id }) {
                    record.state = .failed("Another plugin with id \(record.id) was already loaded.")
                } else if !isBundled, approvals[record.id] != record.sha256 {
                    record.state = .needsApproval
                } else if case .failed = record.state {
                    // Inspection failed; keep the reason.
                } else {
                    let (state, made) = load(url, reserved: &ids)
                    record.state = state
                    extensions += made
                }
                records.append(record)
            }
        }
        return (records, extensions)
    }

    /// The bundle's binary: CFBundleExecutable, or (bundles built without that key) the only
    /// file in Contents/MacOS.
    static func executable(of url: URL) -> URL? {
        if let named = Bundle(url: url)?.executableURL { return named }
        let folder = url.appending(path: "Contents/MacOS")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.count == 1 ? files[0] : nil
    }

    static func inspect(_ url: URL, bundled: Bool) -> PluginRecord {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let id = info[DashPluginKeys.id] as? String ?? url.deletingPathExtension().lastPathComponent
        let version = info[DashPluginKeys.version] as? String ?? "?"
        let executable = executable(of: url)
        let hash = executable.flatMap { try? Data(contentsOf: $0) }.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        var record = PluginRecord(id: id, version: version, url: url, bundled: bundled, sha256: hash, signature: signature(of: url), state: .needsApproval)
        record.info = bundle?.url(forResource: "plugin", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(PluginInfo.self, from: $0) }
        if bundle == nil || executable == nil {
            record.state = .failed("Not a loadable bundle (no executable).")
        } else if let minimum = info[DashPluginKeys.minimumDashKit] as? String, ExtensionMetadata.compare(DashKitInfo.version, minimum) == .orderedAscending {
            record.state = .failed("Needs DashKit \(minimum); this Dash has \(DashKitInfo.version).")
        }
        return record
    }

    static func load(_ url: URL, reserved ids: inout Set<String>) -> (PluginRecord.State, [any DashExtension]) {
        guard let bundle = Bundle(url: url) else { return (.failed("Can't open the bundle."), []) }
        let symbol: UnsafeMutableRawPointer?
        if bundle.executableURL != nil {
            do {
                try bundle.loadAndReturnError()
            } catch {
                return (.failed("Couldn't load: \(error.localizedDescription)"), [])
            }
            symbol = CFBundleCreate(nil, url as CFURL).flatMap { CFBundleGetFunctionPointerForName($0, DashPluginFactory.entrySymbol as CFString) }
        } else {
            // Built without CFBundleExecutable: open the binary directly.
            guard let binary = executable(of: url), let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                return (.failed("Couldn't load: \(String(cString: dlerror()))"), [])
            }
            symbol = dlsym(handle, DashPluginFactory.entrySymbol)
        }
        guard let symbol else {
            return (.failed("No \(DashPluginFactory.entrySymbol) entry point (see docs/PLUGINS.md)."), [])
        }
        typealias Entry = @convention(c) () -> UnsafeMutableRawPointer
        let pointer = unsafeBitCast(symbol, to: Entry.self)()
        let factory = Unmanaged<DashPluginFactory>.fromOpaque(pointer).takeRetainedValue()
        var made: [any DashExtension] = []
        var skipped: [String] = []
        for item in factory.make() {
            if ids.insert(item.id).inserted { made.append(item) } else { skipped.append(item.id) }
        }
        if !skipped.isEmpty, made.isEmpty { return (.failed("Ids already in use: \(skipped.joined(separator: ", ")).") , []) }
        return (.loaded(extensionIDs: made.map(\.id)), made)
    }

    /// Who signed the bundle, read with the Security framework.
    static func signature(of url: URL) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return "unsigned" }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return "invalid signature" }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dictionary = info as? [String: Any] ?? [:]
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String { return "Team \(team)" }
        return "ad-hoc signed"
    }
}

/// Loads plugins while Dash runs: right after a Marketplace install, or when a `.dashplugin`
/// appears in the Plugins folder (asking for approval first). Code can't be unloaded, so a plugin
/// that's already loaded is replaced or removed at the next launch.
@MainActor
final class HotPlugins {
    static let shared = HotPlugins()

    private weak var host: ExtensionHost?
    private var watcher: DispatchSourceFileSystemObject?
    private var folderHandle: Int32 = -1
    /// Bundles already asked about this session (no repeated prompts for a declined one).
    private var asked: Set<String> = []
    private var scanning = false

    /// Watches the Plugins folder for new bundles.
    func start(host: ExtensionHost) {
        self.host = host
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: PluginLoader.userFolder, withIntermediateDirectories: true)
        folderHandle = open(PluginLoader.userFolder.path, O_EVTONLY)
        guard folderHandle >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folderHandle, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Copies land in several writes; look once things settle.
                Task { try? await Task.sleep(for: .milliseconds(600)); await self?.scan() }
            }
        }
        let handle = folderHandle
        source.setCancelHandler { close(handle) }
        source.resume()
        watcher = source
    }

    /// New bundles in the folder: load approved ones, ask about the others.
    func scan() async {
        guard let host, !scanning else { return }
        scanning = true
        defer { scanning = false }
        let urls = ((try? FileManager.default.contentsOfDirectory(at: PluginLoader.userFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "dashplugin" }
        for url in urls {
            let record = PluginLoader.inspect(url, bundled: false)
            if let existing = host.plugins.first(where: { $0.id == record.id }) {
                // Already known: a changed build is picked up at the next launch.
                if existing.sha256 != record.sha256, !asked.contains(record.sha256) {
                    asked.insert(record.sha256)
                    host.activity.emit("plugin.updated", source: "dashboard", title: "\(record.id) \(record.version) is ready",
                                       detail: "Relaunch Dash to switch to the new build.", importance: .notable)
                }
                continue
            }
            if case .failed = record.state { host.plugins.append(record); continue }
            if PluginLoader.approvals[record.id] != record.sha256 {
                guard !asked.contains(record.sha256) else { continue }
                asked.insert(record.sha256)
                let allowed = await host.permissionCenter.ask(
                    icon: record.info?.icon ?? "puzzlepiece.extension", title: "Load “\(record.displayName)” \(record.version)?",
                    message: "A plugin runs inside Dash with the same access to your Mac and accounts as Dash itself. Only load plugins you trust.",
                    details: (record.info?.details(installed: Set(host.extensions.map(\.id))) ?? [])
                        + [.init(title: "Signed by", text: record.signature), .init(title: "SHA-256", text: record.sha256),
                           .init(title: "Location", text: url.path)],
                    allowLabel: "Load Plugin", denyLabel: "Not Now")
                guard allowed else { var declined = record; declined.state = .needsApproval; host.plugins.append(declined); continue }
                PluginLoader.approve(record)
            }
            load(url)
        }
    }

    /// Loads one approved bundle now and hands its extensions to the host.
    @discardableResult
    func load(_ url: URL) -> PluginRecord? {
        guard let host else { return nil }
        var record = PluginLoader.inspect(url, bundled: false)
        if host.plugins.contains(where: { $0.id == record.id && $0.isLoaded }) { return record }
        var ids = Set(host.extensions.map(\.id))
        if case .failed = record.state {} else {
            let (state, made) = PluginLoader.load(url, reserved: &ids)
            record.state = state
            do { try host.addHotLoaded(made) } catch {
                record.state = .failed("Couldn't add its data to the store: \(error.localizedDescription)")
            }
        }
        host.plugins.removeAll { $0.id == record.id }
        host.plugins.append(record)
        if case .failed(let reason) = record.state {
            DashLog.error("Plugin \(record.id): \(reason)", category: "plugins")
        }
        return record
    }
}

extension PluginRecord {
    var isLoaded: Bool { if case .loaded = state { return true }; return false }
}
