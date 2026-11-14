import DashKit
import DashKitUI
import Foundation
import Security
import SwiftUI

/// Where Dash keeps tokens (API keys, passwords). The keychain is the safest, but an app signed
/// ad hoc (development builds) is a new app to it after every rebuild, so macOS asks for your
/// password again and again. Those builds use an owner-only file instead, unless you choose the
/// keychain.
enum SecretStorage {
    static let key = "secrets.backend"

    /// The saved choice, else the encrypted database.
    static var current: SecretBackend {
        UserDefaults.standard.string(forKey: key).flatMap(SecretBackend.init(rawValue:)) ?? .database
    }

    static func apply() {
        Keychain.vault = DatabaseVault.shared
        Keychain.backend = current
        SecretField.savedLabel = current.savedLabel
    }

    /// True when the app has no signing team (ad hoc or unsigned).
    static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        return ((info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String) == nil
    }

    /// Switches, moving the secrets across so nothing has to be typed again.
    @discardableResult
    static func switchTo(_ backend: SecretBackend) -> Int {
        guard backend != Keychain.backend else { return 0 }
        let moved = Keychain.move(from: Keychain.backend, to: backend)
        UserDefaults.standard.set(backend.rawValue, forKey: key)
        Keychain.backend = backend
        SecretField.savedLabel = backend.savedLabel
        return moved
    }
}

struct SecretsSection: View {
    @State private var backend = Keychain.backend
    @State private var message: String?
    @State private var keychainItems = Keychain.keychainAccounts().count
    @State private var fileItems = Keychain.accounts(in: .file).count

    var body: some View {
        Section {
            Picker("Store tokens in", selection: Binding(get: { backend }, set: { choose($0) })) {
                Text("Dash's database, encrypted (no prompts)").tag(SecretBackend.database)
                Text("A private file (no prompts)").tag(SecretBackend.file)
                Text("The macOS keychain").tag(SecretBackend.keychain)
            }
            ForEach([SecretBackend.keychain, .file].filter { $0 != backend }, id: \.self) { other in
                let count = other == .keychain ? keychainItems : fileItems
                if count > 0 {
                    HStack {
                        Text("\(count) token\(count == 1 ? "" : "s") still in \(other == .keychain ? "the keychain" : "the file").").foregroundStyle(.secondary)
                        Spacer()
                        Button("Move Them Here") {
                            let moved = Keychain.move(from: other, to: backend)
                            refreshCounts()
                            message = "Moved \(moved) token\(moved == 1 ? "" : "s")." + (other == .keychain ? " macOS won't ask again." : "")
                        }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Tokens")
        } footer: {
            switch backend {
            case .database:
                Text("Encrypted in Dash's database with a key protected by \(DatabaseVault.shared.protection). A copy of the database can't be read on another Mac.")
            case .file:
                Text("Kept in \((Keychain.fileURL.path as NSString).abbreviatingWithTildeInPath), readable only by your user account (like ~/.aws/credentials). Not encrypted.")
            case .keychain:
                Text("Kept in the keychain. While Dash is a development build (signed ad hoc), macOS asks for your password after each rebuild.")
            @unknown default:
                EmptyView()
            }
        }
    }

    private func refreshCounts() {
        keychainItems = Keychain.keychainAccounts().count
        fileItems = Keychain.accounts(in: .file).count
    }

    private func choose(_ new: SecretBackend) {
        let moved = SecretStorage.switchTo(new)
        backend = new
        refreshCounts()
        message = moved > 0 ? "Moved \(moved) token\(moved == 1 ? "" : "s")." : nil
    }
}
