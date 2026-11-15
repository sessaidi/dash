import CryptoKit
import DashKit
import Foundation
import SwiftData

/// One encrypted secret: the AES-GCM box of its value, sealed with a key derived (ECDH) from the
/// Mac's Secure Enclave key and a fresh ephemeral key whose public half is stored alongside.
@Model
final class StoredSecret {
    @Attribute(.unique) var account: String
    /// ephemeral P-256 public key (65 bytes, x9.63) + AES-GCM combined box.
    var sealed: Data
    var updatedAt: Date

    init(account: String, sealed: Data) {
        self.account = account
        self.sealed = sealed
        updatedAt = .now
    }
}

/// Dash's `.database` secret store: encrypted rows in its SwiftData store, readable only on this
/// Mac. The private key lives in the Secure Enclave (Dash keeps only an opaque handle that the
/// chip alone can use); without one, a random key in an owner-only file is used instead.
final class DatabaseVault: SecretVault, @unchecked Sendable {
    static let shared = DatabaseVault()

    private let lock = NSLock()
    private var container: ModelContainer?
    private var enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey?
    private var fileKey: SymmetricKey?

    /// Where the Secure Enclave key's handle (or the fallback key) is kept.
    var keyURL = URL.applicationSupportDirectory.appending(path: "Dash/vault.key")

    /// How values are protected, for Settings.
    var protection: String {
        lock.withLock { loadKeys() }
        return enclaveKey != nil ? "Secure Enclave" : "a key file (this Mac has no Secure Enclave)"
    }

    /// The store to write to; set again when the container is rebuilt (plugins with models).
    func attach(_ container: ModelContainer) {
        lock.withLock { self.container = container }
    }

    // MARK: SecretVault

    func read(_ account: String) -> String? {
        lock.withLock {
            guard let row = fetch(account), let data = try? open(row.sealed) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func write(_ value: String?, for account: String) -> Bool {
        lock.withLock {
            guard let container else { return false }
            let context = ModelContext(container)
            let existing = try? context.fetch(FetchDescriptor<StoredSecret>(predicate: #Predicate { $0.account == account })).first
            if let value, !value.isEmpty {
                guard let sealed = try? seal(Data(value.utf8)) else { return false }
                if let existing {
                    existing.sealed = sealed
                    existing.updatedAt = .now
                } else {
                    context.insert(StoredSecret(account: account, sealed: sealed))
                }
            } else if let existing {
                context.delete(existing)
            }
            return (try? context.save()) != nil
        }
    }

    func accounts() -> [String] {
        lock.withLock {
            guard let container else { return [] }
            return ((try? ModelContext(container).fetch(FetchDescriptor<StoredSecret>())) ?? []).map(\.account).sorted()
        }
    }

    // MARK: Crypto

    private func fetch(_ account: String) -> StoredSecret? {
        guard let container else { return nil }
        return try? ModelContext(container).fetch(FetchDescriptor<StoredSecret>(predicate: #Predicate { $0.account == account })).first
    }

    /// Loads (or creates) the key: the Secure Enclave one when the chip is there, else a file key.
    private func loadKeys() {
        guard enclaveKey == nil && fileKey == nil else { return }
        let files = FileManager.default
        try? files.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stored = try? Data(contentsOf: keyURL)
        if SecureEnclave.isAvailable {
            if let stored, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored) {
                enclaveKey = key
                return
            }
            if stored == nil, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
                save(key.dataRepresentation)
                enclaveKey = key
                return
            }
        }
        if let stored, stored.count == 32 {
            fileKey = SymmetricKey(data: stored)
        } else if stored == nil {
            let key = SymmetricKey(size: .bits256)
            save(key.withUnsafeBytes { Data($0) })
            fileKey = key
        }
    }

    private func save(_ data: Data) {
        FileManager.default.createFile(atPath: keyURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    struct VaultError: Error {}

    func seal(_ plaintext: Data) throws -> Data {
        loadKeys()
        if let enclaveKey {
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let key = try derive(enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral.publicKey), ephemeral.publicKey)
            return ephemeral.publicKey.x963Representation + (try AES.GCM.seal(plaintext, using: key).combined ?? Data())
        }
        guard let fileKey else { throw VaultError() }
        return try AES.GCM.seal(plaintext, using: fileKey).combined ?? Data()
    }

    func open(_ sealed: Data) throws -> Data {
        loadKeys()
        if let enclaveKey {
            guard sealed.count > 65 else { throw VaultError() }
            let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: sealed.prefix(65))
            let key = try derive(enclaveKey.sharedSecretFromKeyAgreement(with: publicKey), publicKey)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.dropFirst(65)), using: key)
        }
        guard let fileKey else { throw VaultError() }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: fileKey)
    }

    private func derive(_ secret: SharedSecret, _ publicKey: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("dev.sessaidi.Dash.vault".utf8),
                                       sharedInfo: publicKey.x963Representation, outputByteCount: 32)
    }
}
