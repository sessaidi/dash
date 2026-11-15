# The Dash plugin SDK

Everything in Dash beyond the dashboard, Dashii (the assistant) and the Marketplace is a
**plugin**: a `.dashplugin` bundle compiled against **DashKit 2**. Plugins install while Dash runs
(no rebuild, no relaunch) and keep working across Dash updates of the same major version.

There are two kinds, and features build on integrations:

- An **integration** holds an account or a local service: credentials in the Keychain, an
  authenticated `IntegrationConnection`, a status, and non-secret `exports`. Examples: GitHub,
  Atlassian, AWS, Google Cloud, Docker, Kubernetes.
- A **feature** adds widgets, Dashii tools, AI tasks and background work. It declares the
  integrations it `requires` (or uses when present, `optional`) and reaches them only through
  DashKit (`host.integration("github")?.connection`), never by importing another plugin. So
  anyone can write a feature on top of anyone's integration. Examples: Pull Requests, Jira
  Board, Agents, Zoom.

The first-party plugins live in the [dash-registry](https://github.com/sessaidi/dash-registry)
repository (locally `~/code/dash-registry`), which is also a Marketplace registry.

## Quick start

From the registry repository:

```sh
scripts/new-plugin.py Weather --feature                         # or --integration
scripts/new-plugin.py Standup --feature --requires atlassian,github --author "Ada <ada@example.com>"
TEST=1 scripts/build-plugins.sh Weather                         # build, test, zip, index
```

**Try it live:** copy `build/<Name>/Build/Products/Release/<Name>Plugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`. Dash notices it, asks you to load it, and starts
it right away. Its widgets appear in the widget gallery and its tools reach Dashii.

## Layout

One folder per concern, one widget per folder:

```
plugins/Tickets/
├── project.yml, Info.plist, plugin.json
├── Rules/tickets.md                 what Dashii follows when your tools run (Markdown)
├── Sources/
│   ├── TicketsPlugin.swift          entry point
│   ├── TicketsFeature.swift         the DashExtension: ids, settings, start/stop
│   ├── Tools/                       DashiiTools, DashiiFunctions
│   ├── Query/                       DashQL datasets and verbs
│   ├── Widgets/Board/
│   │   ├── BoardWidget.swift        manifest: kind, names, sizes, Config, configSchema, actions
│   │   ├── BoardProvider.swift      WidgetDataProvider: Config → Snapshot
│   │   ├── BoardSnapshot.swift      plain Sendable data, with a sample for previews
│   │   └── BoardView.swift          renders a Snapshot, picks a layout from WidgetLayout
│   └── Presets.swift                hook presets
└── Tests/
```

Views never fetch: they render a snapshot, so the gallery preview, tests and the real widget
share one view. Write one view that adapts to `WidgetLayout` (narrow, medium, wide, large)
rather than one view per size; split a size into its own file only when its layout really differs.

## Entry point

```swift
import DashKit

enum WeatherPlugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [WeatherFeature()] }
}

/// What Dash calls when it loads the bundle.
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { WeatherPlugin.makeExtensions() }
}
```

One plugin may return several extensions (Docker returns its integration and its Containers
feature).

## How Dash loads plugins

- **Install from the Marketplace:** Dash downloads the zip at the registry's pinned commit,
  refuses it if its SHA-256 differs from `registry.json`, checks `DashKitMinimumVersion`, puts
  the bundle in the Plugins folder, approves that exact build and **loads it immediately**.
  Newly installed plugins start turned off; the user turns them on.
- **Drop into the Plugins folder:** Dash asks before loading anything it hasn't approved
  (approval is pinned to the executable's SHA-256; a changed binary asks again).
- **Data:** a plugin's SwiftData models join the store. When a hot-loaded plugin brings new
  models, Dash grows the store's schema on the spot (adding models is a lightweight migration).
- **Update or remove:** Swift code can't be unloaded, so a plugin that's already loaded stops
  right away (its background work and tools go quiet) and the new build, or its absence, takes
  effect at the next launch. Dash says so and offers to relaunch.

## The API (DashKit)

**Every extension** (`DashExtension`): `id`, `name`, `systemImage`, `metadata` (version, author,
summary, category, tags, links, `minimumDashKit`), `requires`/`optional`, `models`, `secretKeys`
and `secrets` (`SecretStore`, Keychain; `legacy` lists older account names to read), `preferences`
(UserDefaults under its id), `widgets`, `tools`, `aiTasks`, `datasets`, `verbs`, `hookPresets`,
`settingsView()`, `start(host:)`, `prepare(host:)` (awaited at launch while the splash shows
progress), `stop()`.

**Integrations** add `isConnected`, `connectionState` (use `state(error:configured:account:)`),
`connection` (`IntegrationConnection`: base URL, headers, extra hosts, per-request `sign`, a
custom `session` or `transport`) and `exports`.

**The host** (`ExtensionContext`, passed to `start` and in `WidgetContext.host`): the shared
SwiftData `context`, the other `extensions` (`host.integration(id)`, `host.ext(Type.self)`),
`permissions` (`ask(PermissionPrompt)`, the permission modal), `dashii` (`DashiiService`),
`activity` (what Dashii reads before each turn; `onEmit` returns an `ActivitySubscription` to
cancel in `stop()`), `askDashii`, `openManager`, `addWidget`, and `aiSettings(scope, tasks:)`.

### Widgets

`DashboardWidget`: a typed `Config` (JSON for Dashii, with a `configSchema`), `content`, optional
`settings`, `snapshot` (what Dashii reads), `defaultSize`, `sizeLimits` (`GridLimits` in cells:
12 columns, 40 pt rows), `aiTasks`, `actions` (what Dashii may do to it: temporary UI state),
`queryFields` (what its DashQL filter bar knows), and `preview(config:)`: a view drawn from
sample data for the gallery and Settings. A preview must not touch the network, accounts or
local services.

Load data with a **`WidgetDataProvider`** and render it with **`ProvidedWidget`**, which handles
the first load, refreshes while the widget is on screen and the app is active, loading and
failure states, Retry, and a stale badge when a reload failed (the last snapshot stays):

```swift
struct BoardProvider: WidgetDataProvider {
    let host: any ExtensionContext
    var refresh: WidgetRefresh { .every(.seconds(120)) }
    func snapshot(for config: BoardConfig) async throws -> BoardSnapshot { … }
}

static func content(config: Binding<BoardConfig>, context: WidgetContext) -> some View {
    ProvidedWidget(BoardProvider(host: context.host), config: config.wrappedValue) { snapshot, layout in
        BoardView(snapshot: snapshot, layout: layout)
    }
}

/// Previews are measured like the real card, so `\.widgetLayout` drives the same layouts.
static func preview(config: BoardConfig) -> some View { BoardResponsiveView(snapshot: .sample) }
```

### Dashii tools and functions

**Tools** (`DashiiTool`): a name, description, JSON-schema properties, `requiresApproval` for
anything that changes things, `writesRemotely` for anything that writes to another service
(Dash never gives those to Dashii or agents).

**Functions** (`DashiiFunction<Input, Output>`): one job Dashii does for you, typed. The
instructions and output schema live in one place; the input is encoded for you (JSON, or
`CompactFormat` for row-heavy input); the answer is decoded, checked, asked for once more with
what was wrong, and optionally cached:

```swift
static let triage = DashiiFunction<AlertContext, Triage>(
    name: "alerts.triage", version: 1, task: "triage",
    instructions: "Find the most likely cause. Cite the rows you used.",
    outputSchema: Triage.schema, model: .fast, inputFormat: .compact, cacheFor: .seconds(600),
    check: { guard !$0.evidence.isEmpty else { throw ToolError("cite evidence") } })

let triage = try await Self.triage.run(context, dashii: host.dashii, settings: host.aiSettings(.extension(id), tasks: aiTasks))
```

With `task`, the user's model and effort for that AI task apply and usage is attributed to it.
Bump `version` when the instructions change (it's part of the cache key).

**AI tasks** (`AITask`): declare what you ask Dashii to do, the models that suit it
(`DashiiModel`: strong, balanced, fast, deep), efforts, an optional on/off switch, and prompt
templates with `{{variables}}`. Dash shows them in an **AI** tab (per widget, or per extension).

### DashQL

Dashii and agents work in Dash through DashQL. Make your data and actions part of it:

- **Datasets** (`QueryDataset`): rows Dashii can query (`from tickets where status = open`), with
  typed fields and `aliases` (other words for the dataset).
- **Verbs** (`DashQLVerb`): statements mapped to your tools, so Dashii writes
  `ticket follow KAN-123` instead of a tool call. Words after the action fill `arguments` in
  order; `presets` fix inputs (`ticket unfollow` is `jira_follow` with follow=false). They go
  through the same approvals as the tool.

### Automation

- **Rules** (`Rules/<id>.md` in the bundle, loaded by the default `defaultRules`): instructions
  Dashii follows when your tools or AI tasks run. Users can change them; Dashii can only propose.
- **Hook presets** (`hookPresets`, built with `HookPresetLibrary`): ready-made watchers (a DashQL
  query run without Dashii that fires on new rows), notifications and agent wake-ups for your data.
- `defaultCommands` (`/commands`) and `events` (every activity kind you `emit`).

### More

**Home suggestions** (`suggestions`), **knowledge** (`knowledge: [KnowledgeEntity]`, ids
`"<kind>:<key>"`, links to `repo:`/`repofile:`), **agents** (`agents: [AgentDefinition]`: role,
instructions, scope, read-only or act-with-approval, schedule, a `precheck` that can skip idle
runs, an `AgentReport` at the end), **activity series** (counts per day for the heatmap).

**UI** (DashKitUI): `StateView`, `ItemRow`, `MetricView`, `Badge`, `StatusDot`, `Tone`,
`SecretField`, `ConnectionStatusLabel`, `AsyncButton`, `RelativeTime`, `DetailScaffold`,
`ActivityHeatmap`. Use them so plugins look like Dash.

## Testing (DashKitTesting)

`import DashKitTesting` in your test target:

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

- `TestHost`: an in-memory store for your models, `runTool`, recorded `askedDashii`,
  `openedManager`, `addedWidgets`, `disabled` ids and `aiChoices`.
- `TestDashii`: queued `replies`, `error`, and every call with its model, effort and source. Test
  a `DashiiFunction` by queuing its JSON answers.
- `TestPermissions`: `answer` and what was `asked`.
- `TestIntegration` and `StubHTTP`: a stand-in integration whose connection goes through canned
  responses per host.
- `WidgetSnapshotLoader(provider:)`: run a provider without a view (`load`, `snapshot`, `isStale`).
- `knowledgeIssues(entities)`: what's wrong with what you hand the knowledge graph.

Never call real services, spawn processes or push in tests.

## Rules for plugin code

- **Integrations fetch, features read.** An integration talks to its service and keeps the data
  in Dash's database or in `exports`; features build on that data and on the integration's tools.
- Swift 6 with strict concurrency; extensions, providers and views are `@MainActor`.
- Integrations do everything in-process (URLSession, Security, CryptoKit, Network); no `Process`.
  Features may run local tools only when that's their purpose (Agents runs `git` and `claude`).
- Requests go through `IntegrationConnection`, so features get auth without seeing secrets.
- Keep ids, widget kinds, tool names, verbs and preference keys stable across versions.
- A plugin runs with Dash's own access. Be explicit in the permission modal about anything
  sensitive, and mark tools `requiresApproval` / `writesRemotely` truthfully.

## Compatibility

DashKit is built with library evolution. Within a major version it only grows: new protocol
requirements come with defaults, new parameters with default values, public enums are switched
with `@unknown default`, stored value types decode old data.

A new **major** version may break the API. Dash refuses a plugin built for another major (the
user is told to update it from the Marketplace) and one needing a newer minor than it has. Set
`DashKitMinimumVersion` (and `metadata.minimumDashKit`) to `2.0.0` or the minor that added the
newest API you use.

## Publishing

1. `TEST=1 scripts/build-plugins.sh <Name>` writes `dist/<id>-<version>.dashplugin.zip`.
2. `python3 scripts/build-index.py` regenerates `registry.json` with its SHA-256.
3. Commit `plugins/<Name>`, the zip and `registry.json` together.
4. Anyone can add the repository as a registry in Settings › Marketplace (`owner/name`,
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
