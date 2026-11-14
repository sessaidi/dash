import Foundation
import Security

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

/// Secrets by account name ("<extension id>.<key>"), in the chosen backend. Every extension's
/// `SecretStore` goes through here.
public enum Keychain {
    static let service = "dev.sessaidi.Dash"

    /// Set by Dash before extensions start.
    nonisolated(unsafe) public static var backend: SecretBackend = .keychain
    nonisolated(unsafe) public static var fileURL = URL.applicationSupportDirectory.appending(path: "Dash/secrets.json")
    nonisolated(unsafe) public static var vault: (any SecretVault)?
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
        case .file: lock.withLock { load().keys.sorted() }
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

    @discardableResult
    public static func keychainWrite(_ value: String?, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
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

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func save(_ secrets: [String: String]) -> Bool {
        let files = FileManager.default
        let folder = fileURL.deletingLastPathComponent()
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(secrets)
            // Created owner-only before any secret is written to it.
            if !files.fileExists(atPath: fileURL.path) {
                files.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try data.write(to: fileURL, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    public static func fileRead(_ account: String) -> String? {
        lock.withLock { load()[account] }
    }

    @discardableResult
    public static func fileWrite(_ value: String?, for account: String) -> Bool {
        lock.withLock {
            var secrets = load()
            secrets[account] = (value?.isEmpty ?? true) ? nil : value
            return save(secrets)
        }
    }

    /// Copies Dash's keychain items into the file (macOS asks once per item), then deletes them
    /// from the keychain. Returns how many moved.
    @discardableResult
    public static func moveKeychainToFile() -> Int {
        var moved = 0
        for account in keychainAccounts() {
            guard let value = keychainRead(account), fileWrite(value, for: account) else { continue }
            keychainWrite(nil, for: account)
            moved += 1
        }
        return moved
    }

    /// The reverse: the file's secrets into the keychain, then the file is emptied.
    @discardableResult
    public static func moveFileToKeychain() -> Int {
        let secrets = lock.withLock { load() }
        var moved = 0
        for (account, value) in secrets where keychainWrite(value, for: account) {
            fileWrite(nil, for: account)
            moved += 1
        }
        return moved
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

/// UserDefaults values owned by one extension: keys "<prefix>.<name>".
public struct PreferenceStore: Sendable {
    public let prefix: String

    public init(prefix: String) {
        self.prefix = prefix
    }

    public func key(_ name: String) -> String { "\(prefix).\(name)" }

    public func string(_ name: String) -> String? { UserDefaults.standard.string(forKey: key(name)) }
    public func bool(_ name: String) -> Bool? { UserDefaults.standard.object(forKey: key(name)) as? Bool }
    public func int(_ name: String) -> Int? { UserDefaults.standard.object(forKey: key(name)) as? Int }
    public func set(_ value: Any?, _ name: String) { UserDefaults.standard.set(value, forKey: key(name)) }

    public var storedKeys: [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix + ".") }.sorted()
    }

    public func removeAll() {
        for key in storedKeys { UserDefaults.standard.removeObject(forKey: key) }
    }
}
