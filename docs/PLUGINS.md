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
repository, which is also a Marketplace registry.

## Tutorials

Step by step, on one example (a made-up ticket service called Acme, served on your Mac by a
mock server), with a checkpoint to try in Dash after each step. Start with Tutorial 1's
[Before you start](tutorials/1-integration.md#before-you-start): what to install, and the words
used.

1. [Build an integration](tutorials/1-integration.md): a token in the Keychain, an authenticated
   connection, status, settings and read-only tools.
2. [Build a widget](tutorials/2-widget.md): a provider, a snapshot and a view with a layout per
   size (narrow, medium, wide, large), header controls, actions Dashii can drive, and tests.
3. [Build an agent](tutorials/3-agent.md): without code through Dashii, or as an
   `AgentDefinition` with a schedule, a free precheck and structured reports.

The finished code is in the registry's [`examples/`](https://github.com/sessaidi/dash-registry/tree/main/examples).

## Quick start

From the registry repository:

```sh
scripts/new-plugin.py Weather --feature                         # or --integration
scripts/new-plugin.py Standup --feature --requires atlassian,github --author "Ada <ada@example.com>"
TEST=1 scripts/try-plugin.sh Weather                            # test, build, install in Dash
TEST=1 scripts/build-plugins.sh Weather                         # publish: zip and index
```

**Try it live:** `try-plugin.sh` copies the bundle into `~/Library/Application Support/Dash/Plugins`.
Dash notices it, asks you to load it, and starts it right away (turn it on in Settings ›
Plugins). Its widgets appear in the widget gallery and its tools reach Dashii. Loaded code can't
be swapped, so relaunch Dash to pick up a new build.

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
        BoardView(snapshot: snapshot, family: layout.family)
    }
}

/// Previews are measured like the real card, so `\.widgetLayout` drives the same layouts.
static func preview(config: BoardConfig) -> some View { BoardPreview() }

struct BoardPreview: View {
    @Environment(\.widgetLayout) private var layout
    var body: some View { BoardView(snapshot: .sample, family: layout.family) }
}
```

### Dashii tools and functions

**Tools** (`DashiiTool`): a name, description, JSON-schema properties, `requiresApproval` for
anything that changes things, `writesRemotely` for anything that writes to another service
(Dash never gives those to Dashii or agents). Tools Dashii and agents get read Dash's database
only. A tool that calls a service and that other extensions run by name is declared
`callsService: true` (DashKit 2.4): Dash keeps it away from Dashii, agents and hooks.

**Fetchers** (`DataFetcher`, DashKit 2.3): Dashii and agents never call a service. They read
Dash's database (reader tools, datasets, the knowledge graph). When data is missing or stale,
they ask the integration that owns it to fetch it with `data_fetch`, then read it again. A
fetcher calls the API, stores the result (sanitized) and returns a short receipt, never the raw
payload:

```swift
var fetchers: [DataFetcher] {
    [DataFetcher(name: "acme.ticket", summary: "One ticket with its comments. Read it with acme_ticket.",
                 properties: ["key": JSONSchema.string("KAN-123")], required: ["key"]) { [weak self] input in
        guard let self, let host else { return nil }
        let ticket = Sanitizer.clean(try await api.ticket(input["key"]?.string ?? "")).capped()
        let previous = host.synced.record(kind: "acme.ticket", scope: scope, key: input.queryKey)
        host.synced.upsert([SyncedRecord(kind: "acme.ticket", scope: scope, key: input.queryKey,
                                         value: ["input": input, "data": ticket], source: id)])
        let same = previous?.value["data"] == ticket
        return ["stored": same ? 0 : 1, "unchanged": same ? 1 : 0, "keys": ["acme.ticket/\(input.queryKey)"],
                "synced_at": .string(Date.now.formatted(.iso8601)), "read_with": "acme_ticket {\"key\":\"KAN-123\"}"]
    }]
}
```

Conventions (the GitHub plugin is the reference: `plugins/GitHub/Sources/Fetch`):

- **Names**: `<integration>.<what>` (`github.pull`, `github.checks`, `datadog.logs`). The input
  mirrors the old live tool's input.
- **Receipt**: `{stored, unchanged, keys, synced_at, read_with}`. `unchanged` counts records
  that were fetched again with the same data (their `synced_at` still moves). `read_with` is the
  reader and input to use.
- **Readers**: a Dashii tool for each fetcher, usually with the old tool's name and input. It
  returns the stored data with its `Freshness` (`json` adds `synced_at`, `stale` and
  `refresh`, the `data_fetch` input that refreshes it). When nothing is stored it returns
  `notFetched(fetcher, input:)`: `{"rows": [], "fetched": false, "hint", "refresh"}`. For
  records of one kind, `host.synced.rows(kind:scope:maxAge:refresh:)` pairs each value with its
  freshness. `maxAge` is the integration's freshness window (a setting).
- **Keys and size**: normalize the input (trim, drop empty values) and key the record by
  `input.queryKey`, the hash of its sorted JSON. Include the site, account or cluster in the
  scope. Cap each record with `capped()` (200 KB by default). An oversized list keeps its first
  items and comes back as `{"items", "truncated": true, "total"}`.
- **Expiry**: query-shaped answers (search, logs, metrics, filtered lists) don't stay forever.
  Drop old ones when the kind is stored again (GitHub keeps them a day).
- **Limits and logging**: Dash runs each fetcher at most a few times a minute per fetcher
  (Settings › Dashii, default 6). Every fetch appears in the Debug window's Activity pane as
  `data.fetched`, `data.fetch_failed` or `data.fetch_limited`; its requests appear in Network.

The `Ingestor` package (`Packages/Ingestor`) follows these conventions for you: describe each
resource once (`IngestResource`: kind, reader, input schema, and the route to fetch with the
mapper that keeps what's worth storing, or code of its own) and get the fetchers, readers and
dataset rows. Its `IngestClient` retries passing failures with backoff, sends ETags and pauses on rate limits,
`IngestFeed` lets a widget show the stored data, fetching in the background when it's missing or
stale, and `IngestTable` keeps typed SwiftData tables of what was fetched, in the integration's
own database file, rebuilt from the stored answers whenever that file can't be opened. A feature
that depends on the integration can read those tables read-only (`IngestDatabase.reading`,
`IngestRows`) when it's built with the integration's schema file of the same version.
`IngestSchedule` keeps chosen resources fetched on a cycle the user sets in the integration's
settings (`IngestScheduleSection`), and `summary`/`clear` show and delete what was stored. Link it statically: in `project.yml`, add `Ingestor: { path: "${DASH_ROOT}/Packages/Ingestor" }`
to `packages` and `- package: Ingestor` to the plugin's and the tests' dependencies.

**Functions** (`DashiiFunction<Input, Output>`): one job Dashii does for you, typed. The
instructions and output schema live in one place; the input is encoded for you (JSON, or
`CompactFormat` for row-heavy input); the answer is decoded, checked, asked for once more with
what was wrong, and optionally cached:

```swift
static let triage = DashiiFunction<AlertContext, Triage>(
    name: "alerts.triage", version: 1, task: "triage",
    instructions: "Find the most likely cause. Cite the rows you used.",
    outputSchema: JSONSchema.object(properties: ["cause": JSONSchema.string(""), "evidence": JSONSchema.array("", of: JSONSchema.string(""))],
                                    required: ["cause", "evidence"]),
    model: .fast, inputFormat: .compact, cacheFor: .seconds(600),
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
- `NetworkSentinel` (DashKit 2.4): proves that your Dashii tools read and don't call. Every
  request made while it records is blocked and reported. It sees requests through `HTTP.send`
  and `IntegrationConnection.send` (custom transports included) and through `URLSession.shared`.
  Give every plugin one test over all its tools, once with an empty store and once with data
  fetched. Fetchers and `callsService` tools are skipped:

  ```swift
  #expect(await NetworkSentinel.requests(running: integration.tools, values: ["repo": "acme/billing-api"]) == [])
  ```

  `requests(running:values:inputs:)` runs each tool with a minimal input built from its schema.
  `values` fills properties by name, and `inputs` replaces a tool's whole input. It returns
  `"tool: GET host/path"` for each request. `recording { … }` does the same for any code.

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
requirements come with defaults, new parameters come in a new overload (adding a parameter to an
existing function, even with a default value, changes its symbol and breaks built plugins),
public enums are switched with `@unknown default`, stored value types decode old data.

DashKit 2.1 added the widget's grid span to `WidgetLayout` (`columns`, `rows`): plugins that read
them need `2.1.0`.

DashKit 2.2 added `host.markdown(_:)`: Markdown drawn like a Dash note (headings, lists, tables,
code, callouts, Mermaid diagrams), with GitHub's HTML comments left out. Plugins that call it
need `2.2.0`.

DashKit 2.4 added fetch-then-read: `Freshness`, `SyncedStore.rows(kind:scope:maxAge:refresh:)`,
`notFetched(_:input:)`, `JSONValue.queryKey` and `capped(toBytes:)`, `DashiiTool.callsService`
(with its own initializer) and `isForDashii`, and `NetworkSentinel` in DashKitTesting. Plugins
that use them need `2.4.0`.

A new **major** version may break the API. Dash refuses a plugin built for another major (the
user is told to update it from the Marketplace) and one needing a newer minor than it has. Set
`DashKitMinimumVersion` (and `metadata.minimumDashKit`) to `2.0.0` or the minor that added the
newest API you use.

## Publishing

1. Bump `DashPluginVersion` in `project.yml` (and `Info.plist`).
2. `TEST=1 scripts/build-plugins.sh <Name>` writes `dist/<id>-<version>.dashplugin.zip` and
   regenerates `registry.json` with its SHA-256 (`python3 scripts/build-index.py` does only that).
3. Commit `plugins/<Name>`, the zip and `registry.json` together. If a global gitignore
   excludes `dist/`, add the zip with `git add -f`.
4. Anyone can add the repository as a registry in Settings › Marketplace (`owner/name`,
   `owner/name@branch`, or a local folder).

Bump the version for every release; the Marketplace offers an update when the registry's
version differs from the installed one.

**Labels.** A registry says who publishes it with a top-level `"label"` in `registry.json`
(`"Community"` for the public registry, a company name for a private one); `build-index.py`
keeps it. A plugin can override it with `"label"` in its `plugin.json`. The Marketplace and
Settings › Plugins show it as a badge on each plugin, so you can tell community plugins from
work-only ones at a glance. Plugins copied into the Plugins folder by hand show as "Local".

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
