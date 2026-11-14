# The Dash plugin SDK

Everything in Dash beyond the dashboard, Claude and the Marketplace is a **plugin**: a
`.dashplugin` bundle compiled against **DashKit**. Plugins install while Dash runs (no rebuild,
no relaunch) and keep working across Dash updates.

There are two kinds, and features build on integrations:

- An **integration** holds an account or a local service: credentials in the Keychain, an
  authenticated `IntegrationConnection`, a status, and non-secret `exports`. Examples: GitHub,
  Atlassian, AWS, Google Cloud, Docker, Kubernetes.
- A **feature** adds widgets, Claude tools, AI tasks and background work. It declares the
  integrations it `requires` (or uses when present, `optional`) and reaches them only through
  DashKit (`host.integration("github")?.connection`), never by importing another plugin. So
  anyone can write a feature on top of anyone's integration. Examples: Pull Requests, Jira
  Board, Agents, Workspaces, Zoom.

The first-party plugins live in the [dash-registry](https://github.com/sessaidi/dash-registry)
repository (locally `~/code/dash-registry`), which is also a Marketplace registry.

## Quick start

From the registry repository:

```sh
scripts/new-plugin.py Weather --feature                         # or --integration
scripts/new-plugin.py Standup --feature --requires atlassian,github --author "Ada <ada@example.com>"
TEST=1 scripts/build-plugins.sh Weather                         # build, test, zip, index
```

`new-plugin.py` writes a complete, passing plugin:

| File | What |
|---|---|
| `project.yml` | XcodeGen project: the `.dashplugin` bundle and its test target |
| `Info.plist`, `plugin.json` | Bundle info; registry metadata (name, kind, icon, description, requires, provides, author) |
| `Sources/<Name>Plugin.swift` | The entry point (below) |
| `Sources/<Name>Integration.swift` | Integration: token in the Keychain, connection, status, settings view, a `_get` tool |
| `Sources/<Name>Feature.swift` | Feature: a widget with a sample preview and size limits, a tool, an AI task |
| `Tests/…` | Swift Testing tests using `DashKitTesting` |

**Try it live:** copy `build/<Name>/Build/Products/Release/<Name>Plugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`. Dash notices it, asks you to load it, and starts
it right away. Its widgets appear in the widget gallery and its tools reach Claude.

## How Dash loads plugins

- **Install from the Marketplace:** Dash downloads the zip at the registry's pinned commit,
  refuses it if its SHA-256 differs from `registry.json`, checks `DashKitMinimumVersion`, puts
  the bundle in the Plugins folder, approves that exact build and **loads it immediately**.
- **Drop into the Plugins folder:** Dash asks before loading anything it hasn't approved
  (approval is pinned to the executable's SHA-256; a changed binary asks again).
- **Data:** a plugin's SwiftData models join the store. When a hot-loaded plugin brings new
  models, Dash grows the store's schema on the spot (adding models is a lightweight migration).
- **Update or remove:** Swift code can't be unloaded, so a plugin that's already loaded stops
  right away (its background work and tools go quiet) and the new build, or its absence, takes
  effect at the next launch. Dash says so and offers to relaunch.
- **Compatibility:** DashKit is built with library evolution, so a plugin built against an older
  DashKit keeps loading in newer Dash builds. DashKit's public API only grows.

## Entry point

```swift
import DashKit

@objc(WeatherDashPlugin)                 // NSPrincipalClass in Info.plist (informational)
final class WeatherPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [WeatherFeature()] }
}

/// What Dash calls when it loads the bundle.
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { WeatherPlugin.makeExtensions() }
}
```

One plugin may return several extensions (Docker returns its integration and its Containers
feature).

## The API (DashKit)

**Every extension** (`DashExtension`): `id`, `name`, `systemImage`, `metadata` (version, author,
summary, category, tags, links, `minimumDashKit`), `requires`/`optional`, `models`, `secretKeys`
and `secrets` (Keychain), `preferences` (UserDefaults under its id), `widgets`, `tools`,
`aiTasks`, `settingsView()`, `start(host:)`, `prepare(host:)` (awaited at launch while the
splash shows progress), `stop()`.

**Integrations** add `isConnected`, `connectionState` (use `state(error:configured:account:)`),
`connection` (`IntegrationConnection`: base URL, headers, extra hosts, per-request `sign`, a
custom `session` or `transport`) and `exports`.

**The host** (`ExtensionContext`, passed to `start` and in `WidgetContext.host`): the shared
SwiftData `context`, the other `extensions` (`host.integration(id)`, `host.ext(Type.self)`),
`permissions` (the permission modal), `claude` (Claude Code with the user's login),
`activity` (what Claude reads before each turn), `askClaude`, `openManager`, `addWidget`, and
`aiSettings(scope, tasks:)`.

**Widgets** (`DashboardWidget`): a typed `Config` (JSON for Claude, with a `configSchema`),
`content`, optional `settings`, `snapshot` (what Claude reads), `defaultSize`, `sizeLimits`
(`GridLimits` in cells: 12 columns, 40 pt rows), `aiTasks`, and `preview(config:)`: a view drawn
from sample data for the widget gallery and Settings. A preview must not touch the network,
accounts or local services; without one Dash shows a neutral placeholder.

**Claude tools** (`ClaudeTool`): a name, description, JSON-schema properties, and
`requiresApproval` for anything that writes or costs.

**AI tasks** (`AITask`): declare what you ask Claude to do, the models that suit it
(`ClaudeModel`), efforts, an optional on/off switch, and prompt templates with `{{variables}}`.
Dash shows them in an **AI** tab (per widget, or per extension in Settings). Run them with:

```swift
let settings = host.aiSettings(.extension(id), tasks: aiTasks)
let prompt = settings.render("summarize", "prompt", ["count": "3"])
let text = try await host.claude.complete(task: "summarize", settings: settings, system: "…", prompt: prompt)
```

**Home suggestions** (`suggestions`): what's waiting for the user right now, built from data
you already stored (`Suggestion` with a priority, and a prompt or a link).

**Automation** (`defaultRules`, `defaultCommands`, `events`): instructions Claude follows when
your tools run, `/commands` you offer, and the activity event kinds you emit (declare every
`emit` kind so users can build hooks on it).

**Knowledge** (`knowledge: [KnowledgeEntity]`): hand Dash's knowledge graph what you know, so
Dashii can connect it with the code and with other plugins' data. An entity has an id
`"<kind>:<key>"` (`ticket:PROJ-12`, `pr:acme/api#3`, `agent:<uuid>`, `meeting:<uuid>`,
`person:<login or email>`), a title, searchable text, and typed `links`. Link to the code with
`repo:owner/name` and `repofile:owner/name:path/in/repo.swift`: Dash resolves them to the
user's local clones. Ticket keys in titles and text are linked for you. Read from your stored
data only; Dash asks after each refresh and replaces what you handed in before.

**Agents** (`agents: [AgentDefinition]`): background workers with a `role`, `specialities`,
`instructions` and a `scope` ("only the prod namespace"). They may use the tools you list and
every tool of the `integrations` you name; `access: .readOnly` (default) hides tools that need
approval, `.actWithApproval` allows them and the user approves each call. They run on a
`schedule` (every N minutes and/or on event kinds) or on demand, with Claude Code and the
model/effort the user picks in your AI tab. An optional `precheck` runs first without Claude
and can `.skip("All healthy")`, so idle runs cost nothing. Each run ends in an `AgentReport`
(summary, findings with info/warning/critical severity) stored in Dash's database; warning and
critical findings emit `agent.finding`. Read reports with `host.agentReports(id, limit:)`, run
one with `host.runAgent(id, reason:)` (ids are `"<extension id>.<agent id>"`). Users create
their own agents in Settings › Automation › Agents with the same fields.

**Activity series** (`activitySeries: [ActivitySeries]`): counts per day you can chart (PRs
opened, worktrees created, meetings…). The built-in Activity Heatmap widget lists every
series; `ActivitySeries.countPerDay` and `sumPerDay` do the grouping.

**UI** (DashKitUI): `StateView` (loading, empty, failed, needs connection), `ItemRow`,
`MetricView`, `Badge`, `StatusDot`, `Tone`, `SecretField`, `ConnectionStatusLabel`,
`AsyncButton`, `RelativeTime`, `DetailScaffold`, `ActivityHeatmap` (a calendar heatmap). Use
them so plugins look like Dash.

## Testing (DashKitTesting)

`import DashKitTesting` in your test target (it ships inside the DashKit framework):

```swift
@MainActor
struct WeatherTests {
    @Test func listsForecasts() async throws {
        let host = "api-\(UUID().uuidString.prefix(8)).test"            // one stub host per test
        StubHTTP.serve(host, routes: ["/forecast": #"{"days": []}"#])
        let api = TestIntegration(id: "weather-api", baseURL: URL(string: "https://\(host)")!)
        let feature = WeatherFeature()
        let dash = try TestHost([api, feature])
        dash.start([api, feature])
        #expect(try await dash.runTool("weather_forecast") == ["days": []])
    }
}
```

- `TestHost`: an in-memory store for your models, `runTool`, recorded `askedClaude`,
  `openedManager`, `addedWidgets`, `disabled` ids and `aiChoices`.
- `TestClaude`: queued `replies`, `error`, and every call with its model and effort.
- `TestPermissions`: `answer` and what was `asked`.
- `TestIntegration`: a stand-in integration whose connection goes through `StubHTTP`.
- `StubHTTP`: canned responses per host (`json:`, `routes:`, or a handler) and the requests made.
- `TestHost.runAgent(id, reason:)`: runs an agent like Dash does (precheck, then `TestClaude`
  with the report schema; queue the report JSON in `testClaude.replies`), and `agentReports`.
- `knowledgeIssues(entities)`: what's wrong with what you hand the knowledge graph (ids not
  `"<kind>:<key>"`, duplicates, empty titles, links nowhere). Expect it to be empty.

Never call real services or spawn processes in tests.

## Rules

- **Integrations fetch, features read.** An integration talks to its service (API, socket,
  CLI) and keeps the data in Dash's database or in `exports`; features build on that data and
  on the integration's tools, and never call the service themselves. Many features can then
  share one integration's data, and offline features keep working.

- Swift 6 with strict concurrency; extensions and views are `@MainActor`.
- Integrations do everything in-process (URLSession, Security, CryptoKit, Network); no `Process`.
  Features may run local tools only when that's their purpose (Agents runs `git` and `claude`).
- Requests go through `IntegrationConnection` (`send`, `get`), so features get auth without
  seeing secrets.
- Keep ids, widget kinds, tool names, model names and preference keys stable across versions:
  users' dashboards, data and settings refer to them.
- A plugin runs with Dash's own access. Be explicit in the permission modal about anything
  sensitive (`host.permissions.ask`), and mark writing tools `requiresApproval`.

## Compatibility

DashKit is built with library evolution: a plugin compiled against an older DashKit keeps
loading in a newer Dash. To keep it that way, DashKit only grows:

- New protocol requirements always come with a default implementation, so existing plugins
  don't have to change.
- New parameters get default values; nothing public is renamed or removed (deprecate first,
  keep it working for at least one major version).
- Public enums are not frozen: `switch` over them with `@unknown default`.
- Value types stored by Dash (`AgentReport`, `AgentFinding`) are `Codable`; new fields are
  optional or defaulted so old data still decodes.
- `DashKitInfo.version` follows semantic versioning: minor for additions, major for removals.
  Set `DashKitMinimumVersion` to the version that introduced the newest API you use (1.2.0
  for knowledge, agents and activity series); Dash refuses to load a plugin that needs a
  newer DashKit than it has, instead of crashing.

## Publishing

1. `TEST=1 scripts/build-plugins.sh <Name>` writes `dist/<id>-<version>.dashplugin.zip` and
   regenerates `registry.json` with its SHA-256.
2. Commit `plugins/<Name>`, the zip and `registry.json` together.
3. Anyone can add the repository as a registry in Settings › Marketplace (`owner/name`,
   `owner/name@branch`, or a local folder).

Bump `DashPluginVersion` in `project.yml` for every release; the Marketplace offers an update
when the registry's version differs from the installed one.

## Contracts of the first-party integrations

Features can rely on these ids, connections and exports:

| id | `connection` | `exports` |
|---|---|---|
| `github` | API URL (default `https://api.github.com`); `Authorization: Bearer`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28` | `login`, `repos` (["owner/name"]), `apiURL` |
| `atlassian` | the site; `Authorization: Basic base64(email:token)`, `Accept: application/json` | `site`, `email`, `accountName` |
| `gitlab` | `<instance>/api/v4`; `PRIVATE-TOKEN` | none |
| `aws` | SigV4-signed requests to `*.amazonaws.com` (`sign`) | none |
| `gcp` | `https://www.googleapis.com`, hosts `[".googleapis.com"]`, `sign` adds a fresh `Authorization: Bearer` | `account`, `credentialsFile` |
| `kubernetes` | the current context's server; a `session` trusting its CA; auth via headers or `sign` | `contexts`, `currentContext`, `namespace`, `server` |
| `docker` | `http://docker` over the Engine API unix socket (`transport`) | `socket`, `version` |
