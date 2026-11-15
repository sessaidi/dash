import Foundation
import Darwin
import Security
import Synchronization

/// Where secrets live. Dash chooses at launch (Settings › Debug).
public enum SecretBackend: String, Sendable, CaseIterable {
    /// The macOS keychain: other apps can't read it, but an app signed ad hoc (development
    /// builds) is a new app to the keychain after every rebuild, so macOS asks for your password.
    case keychain
    /// `~/Library/Application Support/Dash/secrets.json`, readable only by your user (0600),
    /// like `~/.aws/credentials` or `gh`'s config. No prompts.
    case file
    /// Dash's database, each value encrypted with a key held by the Mac's Secure Enclave
    /// (provided by the host as a `SecretVault`). No prompts; useless off this Mac.
    case database
}

extension SecretBackend {
    /// What a filled secret field shows.
    public var savedLabel: String {
        switch self {
        case .keychain: "Saved in Keychain"
        case .file: "Saved in Dash's private file"
        case .database: "Saved, encrypted"
        }
    }

    /// Where an extension's secrets are, for Settings.
    public func location(account: String) -> String {
        switch self {
        case .keychain: "In your login Keychain under “dev.sessaidi.Dash”, account “\(account)”."
        case .file: "In ~/Library/Application Support/Dash/secrets.json (owner-only), key “\(account)”."
        case .database: "Encrypted in Dash's database with a Secure Enclave key, account “\(account)”. Readable only on this Mac."
        }
    }
}

/// A store the host provides for `.database` (Dash: encrypted rows in its database).
public protocol SecretVault: Sendable {
    func read(_ account: String) -> String?
    func write(_ value: String?, for account: String) -> Bool
    func accounts() -> [String]
}

/// Secrets by account name ("<extension id>.<key>"), in the chosen backend. Host-only: extensions
/// use their own `SecretStore`, which can't reach other extensions' secrets.
@_spi(DashHost)
public enum Keychain {
    static let service = "dev.sessaidi.Dash"

    private struct Configuration: Sendable {
        var backend: SecretBackend = .keychain
        var fileURL = URL.applicationSupportDirectory.appending(path: "Dash/secrets.json")
        var vault: (any SecretVault)?
    }
    private static let configuration = Mutex(Configuration())

    /// Where secrets go; set by Dash before extensions start, and when the user switches backend.
    public static var backend: SecretBackend {
        get { configuration.withLock { $0.backend } }
        set { configuration.withLock { $0.backend = newValue } }
    }
    public static var fileURL: URL {
        get { configuration.withLock { $0.fileURL } }
        set { configuration.withLock { $0.fileURL = newValue } }
    }
    public static var vault: (any SecretVault)? {
        get { configuration.withLock { $0.vault } }
        set { configuration.withLock { $0.vault = newValue } }
    }
    private static let lock = NSLock()

    public static func read(_ account: String) -> String? { read(account, in: backend) }

    /// nil or "" deletes the item.
    @discardableResult
    public static func write(_ value: String?, for account: String) -> Bool { write(value, for: account, in: backend) }

    public static func read(_ account: String, in backend: SecretBackend) -> String? {
        switch backend {
        case .keychain: keychainRead(account)
        case .file: fileRead(account)
        case .database: vault?.read(account)
        }
    }

    @discardableResult
    public static func write(_ value: String?, for account: String, in backend: SecretBackend) -> Bool {
        switch backend {
        case .keychain: keychainWrite(value, for: account)
        case .file: fileWrite(value, for: account)
        case .database: vault?.write(value, for: account) ?? false
        }
    }

    public static func accounts(in backend: SecretBackend) -> [String] {
        switch backend {
        case .keychain: keychainAccounts()
        case .file: lock.withLock { ((try? load()) ?? [:]).keys.sorted() }
        case .database: vault?.accounts() ?? []
        }
    }

    /// Moves every secret from one backend to another (reading the keychain asks once per item).
    @discardableResult
    public static func move(from source: SecretBackend, to destination: SecretBackend) -> Int {
        guard source != destination else { return 0 }
        var moved = 0
        for account in accounts(in: source) {
            guard let value = read(account, in: source), write(value, for: account, in: destination) else { continue }
            write(nil, for: account, in: source)
            moved += 1
        }
        return moved
    }

    // MARK: Keychain

    public static func keychainRead(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves (or, for nil or "", deletes) an item. An existing item is updated in place, so a
    /// failed save never loses the value that was there.
    @discardableResult
    public static func keychainWrite(_ value: String?, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Account names of Dash's keychain items (names only: listing doesn't ask for the password).
    public static func keychainAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    // MARK: File

    /// The file's secrets: empty when there's no file yet. A file that can't be read or decoded
    /// throws, so a write never replaces it (and every other secret) with just one key.
    private static func load() throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    /// Writes through a temporary file created owner-only (0600) beside it, then renames it over
    /// the old one: the secrets are never readable by others, even for a moment.
    private static func save(_ secrets: [String: String]) -> Bool {
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(secrets)
            let temporary = folder.appending(path: ".\(fileURL.lastPathComponent).\(UUID().uuidString)")
            let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard descriptor >= 0 else { return false }
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            let synced = fsync(descriptor) == 0
            close(descriptor)
            guard written == data.count, synced, rename(temporary.path, fileURL.path) == 0 else {
                unlink(temporary.path)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    public static func fileRead(_ account: String) -> String? {
        lock.withLock { (try? load())?[account] }
    }

    /// Saves (or removes, for nil or "") one secret. Refuses when the file exists but can't be
    /// read, rather than overwriting the other secrets.
    @discardableResult
    public static func fileWrite(_ value: String?, for account: String) -> Bool {
        lock.withLock {
            guard var secrets = try? load() else {
                DashLog.error("The secrets file can't be read; not writing \(account) over it.", category: "secrets")
                return false
            }
            secrets[account] = (value?.isEmpty ?? true) ? nil : value
            return save(secrets)
        }
    }
}

/// A secret an extension keeps, declared so Settings can show and remove it.
public struct SecretKey: Hashable, Sendable {
    public let key: String
    public let label: String

    public init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }
}

/// Keychain items owned by one extension, stored as account "<extension id>.<key>".
/// `legacy` maps a key to an account name earlier builds used, read as a fallback.
public struct SecretStore: Sendable {
    public let extensionID: String
    public var legacy: [String: String]

    public init(extensionID: String, legacy: [String: String] = [:]) {
        self.extensionID = extensionID
        self.legacy = legacy
    }

    public func account(_ key: String) -> String { "\(extensionID).\(key)" }

    public func read(_ key: String) -> String? {
        Keychain.read(account(key)) ?? legacy[key].flatMap(Keychain.read)
    }

    public func contains(_ key: String) -> Bool { read(key) != nil }

    /// nil or "" removes the item (and its legacy copy).
    public func write(_ key: String, _ value: String?) {
        Keychain.write(value, for: account(key))
        if let old = legacy[key], value?.isEmpty ?? true { Keychain.write(nil, for: old) }
    }

    public func removeAll(_ keys: [SecretKey]) {
        for key in keys { write(key.key, nil) }
    }
}

/// Where extensions keep their settings and state: Dash points it at its database before any
/// extension is made. Plugins default their `UserDefaults` to it instead of `.standard`.
public enum DashStorage {
    private static let lock = NSLock()
    // Guarded by `lock`; UserDefaults itself is thread-safe.
    nonisolated(unsafe) private static var current: UserDefaults = .standard

    /// The extensions' preferences store.
    public static var defaults: UserDefaults { lock.withLock { current } }

    /// Points extensions at the host's store (Dash: its database), before any extension is made.
    @_spi(DashHost)
    public static func use(_ defaults: UserDefaults) { lock.withLock { current = defaults } }
}

/// UserDefaults values owned by one extension: keys "<prefix>.<name>".
public struct PreferenceStore: Sendable {
    public let prefix: String

    public init(prefix: String) {
        self.prefix = prefix
    }

    public func key(_ name: String) -> String { "\(prefix).\(name)" }

    /// Where preferences live: always `DashStorage.defaults` (the host points that at its store).
    public static var defaults: UserDefaults { DashStorage.defaults }
    private var defaults: UserDefaults { Self.defaults }

    public func string(_ name: String) -> String? { defaults.string(forKey: key(name)) }
    public func bool(_ name: String) -> Bool? { defaults.object(forKey: key(name)) as? Bool }
    public func int(_ name: String) -> Int? { defaults.object(forKey: key(name)) as? Int }
    public func set(_ value: Any?, _ name: String) { defaults.set(value, forKey: key(name)) }

    public var storedKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix + ".") }.sorted()
    }

    public func removeAll() {
        for key in storedKeys { defaults.removeObject(forKey: key) }
    }
}
