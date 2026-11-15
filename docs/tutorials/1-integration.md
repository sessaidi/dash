# Tutorial 1: Build an integration

An **integration** connects Dash to one account or service. It owns the credentials, checks
them, and hands everyone else an authenticated connection. Features (widgets, agents, tools)
then use that connection without ever seeing the secret.

In this tutorial you build **Acme**, an integration for a ticket service. It:

- stores an API token in the Keychain,
- checks the token at launch and shows who it belongs to,
- gives features an `IntegrationConnection` that adds `Authorization: Bearer …` to every request,
- gives Dashii two read-only tools: `acme_tickets` and `acme_get`.

The finished code is in the registry repository at
[`examples/Acme`](https://github.com/sessaidi/dash-registry/tree/main/examples/Acme). It builds and its
tests pass. [Tutorial 2](2-widget.md) builds a widget on top of it, and
[Tutorial 3](3-agent.md) adds an agent.

## Before you start

**You need:**

- macOS 26 and Xcode 26, with Dash running on the same Mac.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and Python 3.
- Two checkouts side by side: the plugin registry at `~/code/dash-registry`, and Dash at
  `~/code/perso/dash` (plugins build against its `Packages/DashKit`). If your Dash checkout is
  elsewhere, change the `DashKit: { path: … }` line in your plugin's `project.yml`.

All commands run from the registry's folder. Two scripts do the building:

| Command | What it's for |
|---|---|
| `TEST=1 scripts/try-plugin.sh Acme` | while you work: runs the tests, builds, and installs the plugin in Dash |
| `TEST=1 scripts/build-plugins.sh Acme` | to publish: builds the zip and updates `registry.json` |

The first time a plugin is installed, Dash asks before loading it, and it arrives turned off:
turn it on in **Settings › Plugins**. After that, **relaunch Dash** to switch to a new build
(loaded code can't be swapped while Dash runs). Xcode sometimes prints
`error: the following command failed with exit code 0 but produced no further output`; that line
is harmless. A real failure stops the script.

**The mock server.** Acme is made up, so the registry has a stand-in you run on your Mac:

```sh
python3 examples/MockAcme/server.py          # http://localhost:8787; Ctrl-C stops it
```

It answers two endpoints, like a real service would:

```
GET /me          → {"name": "Ada"}
GET /tickets     → [{"id": "ACME-12", "title": "…", "status": "doing", "priority": "urgent", "assignee": "Ada"}, …]
```

It accepts any token except `wrong`, prints one line per request (so you can watch what Dash
asks for), and reads the tickets from `examples/MockAcme/tickets.json` on every request.

**Words used here:**

| Word | Meaning |
|---|---|
| Dash | the Mac app: pages of widgets, and an assistant |
| Dashii | Dash's assistant. You chat with it; it uses tools to read and act |
| extension | what a plugin adds to Dash: an integration or a feature |
| integration | one account: its credentials, its status, an authenticated connection |
| feature | widgets, tools and agents built on integrations ([Tutorial 2](2-widget.md)) |
| plugin | a `.dashplugin` bundle with one or more extensions, built with DashKit |
| DashKit | the SDK: `DashKit` (models), `DashKitUI` (views), `DashKitTesting` (test helpers) |
| tool | a function Dashii (or an agent) can call: a name, a description, inputs, a body |
| DashQL | Dash's one-line language: `from acme_tickets where priority = "urgent"`, `agent … run` |

## 1. Scaffold it

```sh
scripts/new-plugin.py Acme --integration --author "Ada <ada@example.com>"
```

This creates a working integration:

```
plugins/Acme/
├── project.yml           XcodeGen project: the bundle and its test target
├── Info.plist            DashPluginID, DashPluginVersion, DashKitMinimumVersion
├── plugin.json           what the Marketplace shows (name, kind, icon, description)
├── Rules/acme.md         what Dashii follows when it uses your tools
├── Sources/
│   ├── AcmePlugin.swift          the entry point Dash calls
│   ├── AcmeIntegration.swift     the integration itself
│   └── Tools/AcmeTools.swift     Dashii tools
└── Tests/
```

Sections 2 to 6 walk through what the scaffold wrote, so you know what each part is for.
Sections 7 to 9 are marked **You add**: they turn the scaffold into Acme.

> **Checkpoint.** Run `TEST=1 scripts/try-plugin.sh Acme`. Dash asks to load **Acme**: click
> **Load Plugin**, then turn it on in **Settings › Plugins**. Open its page there: the status
> says it isn't configured. That's right, it has no token yet.

## 2. The entry point

*The scaffold wrote this.* Dash loads the bundle and calls one C function, `dash_plugin_entry`.
It returns the extensions the plugin adds:

```swift
import DashKit

enum AcmePlugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [AcmeIntegration()] }
}

@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { AcmePlugin.makeExtensions() }
}
```

One plugin can return several extensions. For example, Docker returns its integration and its
Containers feature.

## 3. Identity and the secret

*The scaffold wrote this.* An integration is an `@Observable` class on the main actor that
conforms to `Integration`:

```swift
@MainActor
@Observable
final class AcmeIntegration: Integration {
    let id = "acme"                     // stable forever: features find you by it
    let name = "Acme"
    let systemImage = "link"
    let metadata = ExtensionMetadata(version: "1.0.0", author: ExtensionAuthor(name: "Ada", email: "ada@example.com"),
                                     summary: "Connects your Acme account.", category: .other, minimumDashKit: "2.0.0")
    let secretKeys = [SecretKey("token", "API token")]
    let secrets: SecretStore? = SecretStore(extensionID: "acme")

    static let apiURL = URL(string: "https://api.example.com")!
```

- `id` is the contract with every feature: `host.integration("acme")`. Never change it.
- `secretKeys` lists what you keep in the Keychain. `SecretStore(extensionID:)` reads and
  writes it. Secrets never go in preferences, `exports` or logs.

The token, the URL session and the API's address are injected, so tests can replace them:

```swift
    @ObservationIgnored private let readToken: @MainActor () -> String?
    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private var check: Task<Void, Never>?
    private(set) var account: String?
    private(set) var lastError: String?

    init(token: (@MainActor () -> String?)? = nil, session: URLSession? = nil, baseURL: URL = AcmeIntegration.apiURL) {
        let store = SecretStore(extensionID: "acme")
        readToken = token ?? { store.read("token") }
        self.session = session
        self.baseURL = baseURL
    }
```

## 4. Status and the connection

*The scaffold wrote this.* Three properties tell Dash what state the integration is in:

```swift
    private var token: String? { readToken().flatMap { $0.isEmpty ? nil : $0 } }
    var isConnected: Bool { token != nil }
    var connectionState: ConnectionState { state(error: lastError, configured: isConnected, account: account) }
```

`state(error:configured:account:)` turns them into the green, orange or red status shown in
Settings, the Marketplace and the setup checks.

Next comes the **connection**, the most important part. Features send every request through it:

```swift
    var connection: IntegrationConnection? {
        guard let token else { return nil }
        return IntegrationConnection(baseURL: baseURL, headers: ["Authorization": "Bearer \(token)"], session: session)
    }
```

`IntegrationConnection` joins paths onto the base URL, adds the headers, and turns non-2xx
answers into readable errors. `get(_:service:)` returns parsed JSON. Services that don't use a
bearer token fit too (see [Going further](#going-further)).

**Exports** are the non-secret facts features may read, such as the signed-in account:

```swift
    var exports: JSONValue { ["account": account.map { .string($0) } ?? .null] }
```

## 5. Lifecycle: verify the token

*The scaffold wrote this.* `start(host:)` runs when the extension turns on. At launch,
`prepare(host:)` runs after it while the splash screen shows progress, and if it throws, the
user sees the problem:

```swift
    func start(host: any ExtensionContext) {
        if check == nil { verify() }
    }

    func prepare(host: any ExtensionContext) async throws {
        await (check ?? verify()).value          // the check start began: one request, not two
        if let lastError { throw ToolError(lastError) }
    }

    /// A new check cancels the one in flight, so the answer for an old token never wins.
    @discardableResult
    func verify() -> Task<Void, Never> {
        check?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            guard let connection else { lastError = nil; return }
            do {
                let name = try await connection.get("/me", service: name)["name"]?.string
                guard !Task.isCancelled else { return }
                account = name
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
            }
        }
        check = task
        return task
    }
```

`verify()` asks the API who the token belongs to. It keeps the check as a task so that a newer
check replaces an older one: if the user pastes a wrong token and then the right one, the slow
answer for the wrong one is dropped instead of turning the status red.

## 6. Settings

*The scaffold wrote this.* `settingsView()` is the integration's page in Settings. DashKitUI
provides the pieces: `SecretField` (a secure field that never shows the stored secret, with Save
and Remove buttons) and `ConnectionStatusLabel`.

```swift
    func setToken(_ token: String) {
        secrets?.write("token", token)
        account = nil
        verify()
    }

    func settingsView() -> AnyView { AnyView(AcmeSettings(integration: self)) }
}

private struct AcmeSettings: View {
    let integration: AcmeIntegration

    var body: some View {
        Form {
            Section {
                SecretField("API token", isStored: integration.isConnected, onSave: { integration.setToken($0) },
                            onRemove: { integration.setToken("") })
                LabeledContent("Status") { ConnectionStatusLabel(integration.connectionState) }
            } footer: {
                Text("Stored in your Keychain. Features use the connection; they never see the token.")
            }
        }
    }
}
```

## 7. A server setting

**You add.** Acme should talk to the mock server now, and to whatever server the user has later
(many services can be self-hosted). The address isn't a secret, so it's a **preference**: every
extension has its own `preferences` store, saved with Dash's data.

In `AcmeIntegration.swift`, replace the `baseURL` property and the `init` with:

```swift
    @ObservationIgnored private let fixedServer: URL?

    /// `token`, `session` and `server` are for tests; Dash uses the Keychain, the shared session
    /// and the server saved in Settings.
    init(token: (@MainActor () -> String?)? = nil, session: URLSession? = nil, server: URL? = nil) {
        let store = SecretStore(extensionID: "acme")
        readToken = token ?? { store.read("token") }
        self.session = session
        fixedServer = server
    }

    /// Where requests go: the one saved in Settings, else the real service.
    var server: URL { fixedServer ?? preferences.string("server").flatMap(URL.init(string:)) ?? Self.apiURL }
```

In `connection`, use `baseURL: server`. Then add a way to change it. Every request carries the
token, so plain `http` is only allowed to this Mac:

```swift
    /// Points Acme at another server: https, or plain http on this Mac only. False if refused.
    @discardableResult
    func setServer(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let host = url.host() else { return false }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return false }
        preferences.set(url.absoluteString, "server")
        account = nil
        verify()
        return true
    }
```

And a field in `AcmeSettings`, below the token's section:

```swift
    @State private var server = ""
    @State private var refused = false

    // In the Form, after the first Section:
            Section {
                TextField("Server", text: $server, prompt: Text(AcmeIntegration.apiURL.absoluteString))
                    .onSubmit { refused = !integration.setServer(server) }
            } footer: {
                Text(refused ? "Use an https address, or http://localhost for the mock server."
                     : "Press Return to save. The tutorials' mock server is http://localhost:8787.")
                    .foregroundStyle(refused ? .red : .secondary)
            }

    // On the Form:
        .onAppear { server = integration.server.absoluteString }
```

> **Checkpoint.** Start the mock server, run `scripts/try-plugin.sh Acme` and relaunch Dash. On
> Acme's page in **Settings › Plugins**, set **Server** to `http://localhost:8787` (Return),
> then paste any token and save. The status turns green, **Signed in as Ada**, and the server
> prints `GET /me with a token -> 200`. Now save the token `wrong`: the status turns red with
> the server's error. Save a good token again before going on.

## 8. Tools for Dashii

**You add** `acme_tickets`; the scaffold wrote `acme_get`. Tools are how Dashii (and agents)
use your service. Each tool has:

- a name,
- a description written for the model,
- a JSON schema of its inputs,
- an async body that returns JSON.

This is the whole of `Tools/AcmeTools.swift`. The scaffold's `acme_get` and its `apiPath` check
are already there; add `statuses` and `acme_tickets`:

```swift
import DashKit
import Foundation

@MainActor
enum AcmeTools {
    static let statuses = ["todo", "doing", "done"]

    static func tools(integration: AcmeIntegration) -> [DashiiTool] {
        [
            DashiiTool(name: "acme_get", description: "GET an Acme API path and return the JSON. Read-only.",
                       properties: ["path": JSONSchema.string("API path, e.g. /me or /tickets?status=todo.")],
                       required: ["path"]) { [weak integration] input in
                guard let connection = integration?.connection else { throw ToolError("Connect Acme in Settings.") }
                return try await connection.get(try apiPath(input["path"]?.string ?? "/"), service: "Acme")
            },
            DashiiTool(name: "acme_tickets",
                       description: "List Acme tickets: id, title, status (todo, doing, done), priority, assignee. Read-only.",
                       properties: ["status": JSONSchema.string("Only this status; omit for all.", enum: statuses)]) { [weak integration] input in
                guard let connection = integration?.connection else { throw ToolError("Connect Acme in Settings.") }
                // The schema's enum is a hint to the model, not a check: check it here.
                var path = "/tickets"
                if let status = input["status"]?.string {
                    guard statuses.contains(status) else { throw ToolError("status is one of \(statuses.joined(separator: ", ")).") }
                    path += "?status=\(status)"
                }
                return try await connection.get(path, service: "Acme")
            },
        ]
    }

    /// A path on the API, never another host or a parent directory: the model writes it, and
    /// the request carries the user's token.
    static func apiPath(_ path: String) throws -> String {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !route.contains("@"), !route.contains("\\"),
              !route.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              !route.lowercased().contains("%2e"), !route.lowercased().contains("%2f") else {
            throw ToolError("Give an API path starting with /, like /tickets.")
        }
        return path
    }
}
```

The integration lists them with `var tools: [DashiiTool] { AcmeTools.tools(integration: self) }`.

**Treat tool input as untrusted.** The model writes it, and it can be steered by text it read
(a ticket title, a web page). Don't rely on the schema to hold it in (DashQL and agents call
the tool with whatever they parsed), and remember the request carries the user's token. So
check enums yourself, and keep model-written paths on the API, as `apiPath` does.

Be truthful about what a tool does, because Dash relies on it:

| Flag | Meaning | What Dash does |
|---|---|---|
| none | reads only | Dashii and read-only agents may call it freely |
| `requiresApproval: true` | changes something | asks the user before each call (unless they chose Always Allow); agents need `actWithApproval` |
| `writesRemotely: true` | writes to another service | never given to Dashii or agents |

Then tell Dashii how to use the tools in `Rules/acme.md`. It's plain Markdown that users can
edit in the app:

```markdown
- Acme is read through `acme_tickets` (the ticket list) and `acme_get` (any GET path); say which you read.
- Never paste the API token or any credential.
```

> **Checkpoint.** Run `scripts/try-plugin.sh Acme`, relaunch Dash, and ask Dashii "what's urgent
> in Acme?". It calls `acme_tickets` and names ACME-12; the server prints `GET /tickets`. Edit
> `examples/MockAcme/tickets.json` (make ACME-15 urgent) and ask again: the answer follows.

## 9. Test it

**You add** these tests, in place of the scaffold's. `DashKitTesting` gives you `StubHTTP`,
which serves canned answers per host, so tests never touch the network:

```swift
import DashKit
import DashKitTesting
import Foundation
import Testing

@MainActor
struct AcmeIntegrationTests {
    /// An integration whose requests go to a stub host (one per test, so tests don't share answers).
    func make(token: String? = "secret", routes: [String: String] = ["/me": #"{"name": "ada"}"#]) -> (AcmeIntegration, String) {
        let host = "api-\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, routes: routes)
        return (AcmeIntegration(token: { token }, session: StubHTTP.session, server: URL(string: "https://\(host)")!), host)
    }

    @Test func connectsWithATokenAndVerifiesTheAccount() async throws {
        let (integration, host) = make()
        await integration.verify().value
        #expect(integration.connectionState == .connected("Signed in as ada"))
        #expect(StubHTTP.requests(host).first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func aRejectedTokenShowsTheError() async throws {
        let (integration, _) = make(routes: [:])                        // every path answers 404
        await integration.verify().value
        guard case .failed = integration.connectionState else { Issue.record("expected a failure"); return }
    }

    @Test func noTokenMeansNotConnected() {
        let (integration, _) = make(token: nil)
        #expect(!integration.isConnected && integration.connection == nil)
        #expect(integration.tools.allSatisfy { !$0.requiresApproval && !$0.writesRemotely })
    }

    @Test func toolsStayOnTheAPI() async throws {
        let (integration, host) = make(routes: ["/tickets": "[]"])
        let tickets = try #require(integration.tools.first { $0.name == "acme_tickets" })
        _ = try await tickets.run(["status": "todo"])
        #expect(StubHTTP.requests(host).last?.url?.query == "status=todo")
        await #expect(throws: ToolError.self) { try await tickets.run(["status": "todo&admin=1"]) }
        for path in ["https://evil.example/x", "//evil.example/x", "/../admin", "/@evil.example", "me"] {
            #expect(throws: ToolError.self) { try AcmeTools.apiPath(path) }
        }
    }
}
```

The example adds one more: the server setting refuses plain `http` to another host, and a new
launch reads the saved server back.

> **Checkpoint.** `TEST=1 scripts/try-plugin.sh Acme` runs the tests before building. They pass,
> and the mock server prints nothing: tests never leave your Mac's stubs.

## 10. Publish it

Bump `DashPluginVersion` in `project.yml`, run `TEST=1 scripts/build-plugins.sh Acme` (it builds
the zip and regenerates `registry.json`), and commit the plugin, the zip and `registry.json`
together. See [PLUGINS.md](../PLUGINS.md#publishing).

## Checklist

- [ ] `id` is final, short and kebab-case.
- [ ] Secrets only in `SecretStore`; settings that aren't secret in `preferences`; `exports` holds nothing secret.
- [ ] `connection` is nil when not configured; requests go through it.
- [ ] `connectionState` reflects errors (bad token, unreachable).
- [ ] Every tool says truthfully whether it changes things, and checks its input.
- [ ] Tests use `StubHTTP`, one host per test, never call the real service, and run `verify()`.

## Going further

**Other kinds of authentication.** `IntegrationConnection` takes more than headers:

- `sign` signs each request (AWS SigV4, an OAuth token you refresh).
- `hosts` lists more domains that full-URL requests may target (`.googleapis.com`).
- `session` takes a custom `URLSession` (for example, one that trusts a cluster's CA).
- `transport` sends requests your own way (for example, over a unix socket, as Docker does).

**Exports for features.** A feature reads `host.integration("acme")?.exports["account"]` to
show who's signed in, without access to the token. Put there what features need to know about
the account (a login, a site URL, watched repositories), never credentials.

**Stubs that check the request.** `StubHTTP.serve(host) { request in … }` takes a closure, so a
test can answer differently per method or body, and assert what the plugin sent.

Next: [Tutorial 2: Build a widget](2-widget.md).
