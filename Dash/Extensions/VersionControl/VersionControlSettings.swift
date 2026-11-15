import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// Settings shared by the git and jj integrations: which tool, how branches are updated and
/// pulled, conventions, per-repository overrides, and the SSH and signing setup read from disk.
struct VersionControlSettings: View {
    let title: String
    let state: ConnectionState
    @Bindable var preferences: VCSPreferences
    let host: (any ExtensionContext)?
    let check: () async -> Void

    @State private var identity: JSONValue?
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                HStack {
                    ConnectionStatusLabel(state)
                    Spacer()
                    AsyncButton("Check") { await check() }
                }
            } header: {
                Text(title)
            } footer: {
                Text("Runs with your login shell's environment, so your ssh-agent, credential helpers and PATH apply. Nothing is ever pushed.")
            }

            Section {
                SettingsEditor(settings: $preferences.global, inherited: nil)
            } header: {
                Text("Preferences")
            } footer: {
                Text("Dashii reads these before changing a repository (vcs_preferences), and the update tools follow them.")
            }

            Section {
                ForEach(preferences.repositories.keys.sorted(), id: \.self) { path in
                    DisclosureGroup {
                        SettingsEditor(settings: Binding(get: { preferences.repositories[path] ?? VCSPreferences.Settings() },
                                                         set: { preferences.repositories[path] = $0 }),
                                       inherited: preferences.global.over(.defaults))
                        Button("Remove Override", role: .destructive) { preferences.repositories[path] = nil }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent).font(.callout.weight(.medium))
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Menu("Add Repository") {
                    let known = knownRepositories.filter { preferences.repositories[$0] == nil }
                    ForEach(known, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { preferences.repositories[path] = VCSPreferences.Settings() }
                    }
                    if !known.isEmpty { Divider() }
                    Button("Choose Folder…") { chooseFolder() }
                }
                .fixedSize()
            } header: {
                Text("Per repository")
            } footer: {
                Text("A repository's own choices win over the preferences above; anything left on “Same as default” follows them.")
            }

            IdentitySection(identity: identity)
                .task { identity = await VCSIdentity.json(repository: nil) }
        }
        .formStyle(.grouped)
    }

    /// Repositories Knowledge indexes, offered first.
    private var knownRepositories: [String] {
        host?.extensions.compactMap { $0 as? KnowledgeExtension }.first?.repositories ?? []
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.repositories[url.standardizedFileURL.path] = VCSPreferences.Settings()
    }
}

/// Pickers for one set of settings. With `inherited`, each can stay on “Same as default”.
private struct SettingsEditor: View {
    @Binding var settings: VCSPreferences.Settings
    let inherited: VCSPreferences.Settings?

    var body: some View {
        Picker("Tool", selection: $settings.tool) {
            if let inherited { Text("Same as default (\(inherited.tool?.title ?? "auto"))").tag(VCSPreferences.Tool?.none) }
            ForEach(VCSPreferences.Tool.allCases, id: \.self) { Text($0.title).tag(VCSPreferences.Tool?.some($0)) }
        }
        Picker("Update a branch", selection: $settings.update) {
            if let inherited { Text("Same as default (\(inherited.update?.title ?? "rebase"))").tag(VCSPreferences.Update?.none) }
            ForEach(VCSPreferences.Update.allCases, id: \.self) { Text($0.title).tag(VCSPreferences.Update?.some($0)) }
        }
        Picker("Pull", selection: $settings.pull) {
            if let inherited { Text("Same as default (\(inherited.pull?.title ?? "fast-forward only"))").tag(VCSPreferences.Pull?.none) }
            ForEach(VCSPreferences.Pull.allCases, id: \.self) { Text($0.title).tag(VCSPreferences.Pull?.some($0)) }
        }
        Picker("Local changes", selection: $settings.autostash) {
            if let inherited { Text("Same as default (\(inherited.autostash ?? true ? "stash" : "stop"))").tag(Bool?.none) }
            Text("Stash them around the update").tag(Bool?.some(true))
            Text("Stop when there are any").tag(Bool?.some(false))
        }
        TextField("Base branch", text: Binding(get: { settings.base ?? "" }, set: { settings.base = $0.isEmpty ? nil : $0 }),
                  prompt: Text(inherited?.base ?? "From origin (main, master…)"))
        TextField("Conventions", text: Binding(get: { settings.conventions ?? "" }, set: { settings.conventions = $0.isEmpty ? nil : $0 }),
                  prompt: Text(inherited?.conventions ?? "e.g. conventional commits; branches named TICKET-123-short-title"), axis: .vertical)
            .lineLimit(1...4)
    }
}

/// The SSH and signing setup found on disk, read-only.
private struct IdentitySection: View {
    let identity: JSONValue?

    var body: some View {
        Section {
            if let identity {
                let git = identity["git"]
                LabeledContent("Commits as") {
                    Text([git?["user.name"]?.string, git?["user.email"]?.string.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Not set")
                }
                LabeledContent("Signing") {
                    let signing = identity["signing"]
                    Text(signing?["enabled"] == true
                         ? "On · \(signing?["format"]?.string ?? "openpgp")\(signing?["key"]?.string.map { " · \($0)" } ?? "")"
                         : "Off")
                }
                LabeledContent("ssh-agent") { Text(identity["ssh_agent"] == true ? "Running" : "Not found in your shell") }
                ForEach(Array((identity["ssh_hosts"]?.array ?? []).enumerated()), id: \.offset) { _, host in
                    LabeledContent(host["host"]?.string ?? "?") {
                        Text([host["user"]?.string.map { "\($0)@" }, host["hostname"]?.string, host["port"]?.string.map { ":\($0)" }].compactMap { $0 }.joined()
                             + ((host["identity_files"]?.array ?? []).isEmpty ? "" : " · " + (host["identity_files"]?.array ?? []).compactMap(\.string).joined(separator: ", ")))
                            .font(.caption.monospaced()).lineLimit(2)
                    }
                }
                ForEach(Array((identity["ssh_public_keys"]?.array ?? []).enumerated()), id: \.offset) { _, key in
                    LabeledContent((key["file"]?.string as NSString?)?.lastPathComponent ?? "key") {
                        Text("\(key["type"]?.string ?? "") \(key["comment"]?.string ?? "")").font(.caption.monospaced())
                    }
                }
                if let keys = identity["gpg_keys"]?.array {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        LabeledContent("GPG \(key["id"]?.string ?? "")") {
                            Text("\(key["algorithm"]?.string ?? "") · \((key["users"]?.array ?? []).compactMap(\.string).joined(separator: ", "))").font(.caption)
                        }
                    }
                } else if let note = identity["gpg_keys"]?.string {
                    LabeledContent("GPG") { Text(note).foregroundStyle(.secondary) }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("Read from ~/.ssh/config, the public keys in ~/.ssh, your git config and (when installed) gpg. Private keys are never read.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
