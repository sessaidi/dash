# Tutorial 2: Build a widget with a layout per size

A widget is a card on the dashboard. Users resize it on a 12-column grid, so the same widget must
look right as a small square and as a wide panel. Dash doesn't stretch one layout for this. Your
view gets a **size family** and draws a different layout for each:

| Preset | Cells (columns × rows) | Family | What the example shows |
|---|---|---|---|
| Small | 3 × 4 | `narrow` | a count and the most urgent ticket |
| Medium | 4 × 6 | `medium` | a list, most urgent first |
| Wide | 8 × 9 | `wide` | a column per status |
| Large | 6 × 9 | `large` | the columns and the triage agent's last report |

The family follows the widget's grid span, so a Small widget is narrow on any screen. A resized
widget gets the family of its span:

- 3 columns or fewer: `narrow`.
- 4 to 5 columns: `medium`.
- 6 to 7 columns: `large` with 8 rows or more, otherwise `wide`.
- 8 columns or more: `large` with 12 rows or more, otherwise `wide`.

The family only steps down when the window is too narrow for it: under 480 points of content, a
wide or large widget gets `medium`, and under 260 points every widget gets `narrow`. So each
layout can count on that much room (`WidgetLayout.minimumWideWidth`, `minimumMediumWidth`).

This tutorial builds **Acme Board**, a feature with an *Acme Tickets* widget, on the Acme
integration from [Tutorial 1](1-integration.md). The finished code is in
[`examples/AcmeBoard`](https://github.com/sessaidi/dash-registry/tree/main/examples/AcmeBoard)
(it also has Tutorial 3's agent).

**Before you start:** finish [Tutorial 1](1-integration.md), or install its finished example
(`TEST=1 scripts/try-plugin.sh Acme`), and keep the mock server running with Acme signed in to
it. The tools, the scripts and the words used are in Tutorial 1's
[Before you start](1-integration.md#before-you-start).

## The shape of a widget

Four small files, one job each:

```
Sources/Widgets/Tickets/
├── TicketsWidget.swift     manifest: kind, names, sizes, Config, settings, actions, preview
├── TicketsProvider.swift   loads data: Config → Snapshot
├── TicketsSnapshot.swift   plain Sendable data, with a sample for previews
└── TicketsView.swift       draws a Snapshot, one layout per family
```

**Views never fetch.** They draw a snapshot. That's why the gallery preview, the tests and the
real widget can share one view: the preview hands it sample data, the widget hands it real data.

## 1. Scaffold the feature

```sh
scripts/new-plugin.py AcmeBoard --feature --requires acme
```

A **feature** declares the integrations it needs in `requires` and reaches them only through
DashKit. It never imports the integration's code, so anyone can build a feature on anyone's
integration.

The scaffold is a complete feature with sample data: a widget named `Main`, a tool, a summary
by a smaller model, DashQL statements and tests. You'll replace its sample data with Acme's
tickets, then build the widget again as `Tickets`.

> **Checkpoint.** Run `scripts/try-plugin.sh AcmeBoard`, load it, and turn **AcmeBoard** on in
> **Settings › Plugins**. Then **Add Widget**: the gallery has an *AcmeBoard* widget showing
> "First item" and "Second item".

## 2. The feature keeps the data

**You replace** the scaffold's sample data with tickets. The feature reads them through the
integration's connection every minute and keeps them in memory. Widgets, tools and agents all
read that copy.

First clear the way: delete `Sources/Widgets/Main/` (section 5 builds the new widget) and
`Sources/Query/` (it's in [Going further](#going-further)). The scaffold's tests use both, so
until section 10 replaces them, build without `TEST=1`.

A ticket is plain data, read from the integration's JSON. Features never import an
integration's types; they read its JSON. Create `Sources/Models/AcmeTicket.swift`:

```swift
import DashKit
import Foundation

struct AcmeTicket: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let status: String          // todo, doing or done
    let priority: String        // low, normal, high or urgent
    let assignee: String?

    init(id: String, title: String, status: String, priority: String, assignee: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.assignee = assignee
    }

    init(json: JSONValue) {
        self.init(id: json["id"]?.string ?? "", title: json["title"]?.string ?? "", status: json["status"]?.string ?? "todo",
                  priority: json["priority"]?.string ?? "normal", assignee: json["assignee"]?.string)
    }

    var isUrgent: Bool { priority == "urgent" && status != "done" }

    var json: JSONValue {
        ["id": .string(id), "title": .string(title), "status": .string(status), "priority": .string(priority),
         "assignee": assignee.map { .string($0) } ?? .null]
    }

    /// For previews and tests: one in each status, an urgent one, a done one.
    static let samples = [
        AcmeTicket(id: "ACME-12", title: "Checkout fails for EU cards", status: "doing", priority: "urgent", assignee: "Ada"),
        AcmeTicket(id: "ACME-15", title: "Add dark mode to settings", status: "todo", priority: "normal", assignee: nil),
        AcmeTicket(id: "ACME-9", title: "Retry webhooks with backoff", status: "doing", priority: "high", assignee: "Sam"),
        AcmeTicket(id: "ACME-17", title: "Typo on the pricing page", status: "todo", priority: "low", assignee: "Lin"),
        AcmeTicket(id: "ACME-4", title: "Rotate staging credentials", status: "done", priority: "high", assignee: "Ada"),
    ]
}
```

Replace `Sources/AcmeBoardFeature.swift` with the feature:

```swift
import DashKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AcmeBoardFeature: DashExtension {
    let id = "acme-board"
    let name = "Acme Board"
    let systemImage = "ticket"
    let metadata = ExtensionMetadata(version: "1.0.0", author: ExtensionAuthor(name: "Dash"),
                                     summary: "Your Acme tickets on the dashboard.", category: .productivity, minimumDashKit: "2.0.0")
    let layer = ExtensionLayer.feature
    let requires = ["acme"]

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    private(set) var tickets: [AcmeTicket] = []
    private(set) var lastError: String?

    var tools: [DashiiTool] { AcmeBoardTools.tools(feature: self) }

    func start(host: any ExtensionContext) {
        self.host = host
        loop?.cancel()                          // started twice: still one loop
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }  // the feature is gone: so is the loop
                await refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {                           // always undo what start did
        loop?.cancel()
        loop = nil
    }

    /// Reads the tickets through the integration's connection: auth included, token unseen.
    func refresh() async {
        guard let connection = host?.integration("acme")?.connection else {
            lastError = "Connect Acme in Settings."
            return
        }
        do {
            tickets = try await connection.get("/tickets", service: "Acme").array?.map(AcmeTicket.init) ?? []
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func requireHost() throws -> any ExtensionContext {
        guard let host else { throw ToolError("Acme Board isn't running.") }
        return host
    }
}
```

`host` is weak: the host owns the feature, not the other way round. Data that must survive a
relaunch goes in SwiftData (list your `@Model` types in `models` and use `host.context`); small
state goes in `preferences`.

One tool lets Dashii read the tickets. Replace `Sources/Tools/AcmeBoardTools.swift` with:

```swift
import DashKit

@MainActor
enum AcmeBoardTools {
    static func tools(feature: AcmeBoardFeature) -> [DashiiTool] {
        [
            DashiiTool(name: "acme_board_tickets", description: "The Acme tickets Dash has: id, title, status, priority, assignee.") { [weak feature] _ in
                .array((feature?.tickets ?? []).map(\.json))
            },
        ]
    }
}
```

And `Rules/acme-board.md`:

```markdown
- Acme tickets: `acme_board_tickets` (id, title, status, priority, assignee).
```

> **Checkpoint.** Run `scripts/try-plugin.sh AcmeBoard` and relaunch Dash. The mock server
> prints `GET /tickets` once a minute: that's the feature's loop. Ask Dashii "which Acme ticket
> is urgent?": it calls `acme_board_tickets`, which reads the feature's copy without a request
> (the server prints nothing new).

## 3. The snapshot: what the widget shows

Create `Sources/Widgets/Tickets/TicketsSnapshot.swift`:

```swift
struct TicketsSnapshot: Sendable, Equatable {
    var tickets: [AcmeTicket]
    var triage: String?          // the agent's last summary (Tutorial 3)

    static let statuses = ["todo", "doing", "done"]

    static let sample = TicketsSnapshot(tickets: AcmeTicket.samples,
                                        triage: "One urgent ticket: EU card checkouts fail since this morning's deploy; Ada is on it.")
}
```

The sample should fill every layout: tickets in each status, an urgent one, a done one. The
gallery shows it at every size, so a thin sample looks like a broken widget.

## 4. The provider: Config → Snapshot

Create `TicketsProvider.swift`:

```swift
import DashKit

struct TicketsProvider: WidgetDataProvider {
    let host: any ExtensionContext

    var refresh: WidgetRefresh { .every(.seconds(30)) }

    func snapshot(for config: TicketsWidget.Config) async throws -> TicketsSnapshot {
        guard let feature = host.ext(AcmeBoardFeature.self) else { throw ToolError("Acme Board isn't loaded.") }
        // The last read failed: try again now (this is also what Retry does), and if it still
        // fails, say so. The widget keeps the last good snapshot and shows it as stale.
        if feature.lastError != nil { await feature.refresh() }
        if let error = feature.lastError { throw ToolError(error) }
        let order = ["urgent", "high", "normal", "low"]
        let tickets = feature.tickets
            .filter { config.showDone || $0.status != "done" }
            .sorted { (order.firstIndex(of: $0.priority) ?? 9) < (order.firstIndex(of: $1.priority) ?? 9) }
        let triage = host.agentReports("acme-board.triage", limit: 5).first { $0.status != .skipped }?.summary
        return TicketsSnapshot(tickets: tickets, triage: triage)
    }
}
```

`ProvidedWidget` runs the provider for you:

- It loads on first appearance.
- It refreshes on the `refresh` interval, only while the widget is on screen and Dash is active.
- It shows loading, an error with **Retry**, and a "stale" badge when a reload fails. The last
  good snapshot stays on screen.

That's why the provider throws when the feature's last read failed, even with tickets in hand:
returning the old tickets as if they were fresh would hide the badge.

## 5. The manifest

Create `TicketsWidget.swift`:

```swift
import DashKit
import DashKitUI
import SwiftUI

struct TicketsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var showDone = false
    }

    static let kind = "acme-board.tickets"          // stable forever: saved dashboards refer to it
    static let displayName = "Acme Tickets"
    static let summary = "Your Acme tickets: a count when small, a list, columns, or columns with the triage report."
    static let systemImage = "ticket"
    static let defaultSize = WidgetSize.medium
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["showDone": ["type": "boolean", "description": "Also show done tickets."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        ProvidedWidget(TicketsProvider(host: context.host), config: config.wrappedValue) { snapshot, layout in
            TicketsView(snapshot: snapshot, family: layout.family)
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Show done tickets", isOn: config.showDone)
    }

    static func preview(config: Config) -> some View { TicketsPreview() }
}
```

And list it in the feature: `var widgets: [WidgetType] { [WidgetType(TicketsWidget.self)] }`.

- **`Config`** is saved with each placed widget. Dashii can change it too (it reads
  `configSchema`), so describe each field.
- **`sizeLimits`** is in grid cells (12 columns, 40-point rows). Users can't resize the widget
  beyond it. Allow `minW: 3` only if your narrow layout is good.
- **`settings`** appears in the widget's settings sheet. Bind controls straight to `config`.
- **`preview`** draws sample data for the gallery and the plugin's page. It must not touch the
  network, accounts or local services.

## 6. The view: one layout per family

Create `TicketsView.swift`. Its `body` picks a layout per family:

```swift
struct TicketsView: View {
    let snapshot: TicketsSnapshot
    let family: WidgetLayout.Family
    @State private var search = ""         // set by Dashii (section 8)

    /// What the layouts draw: the snapshot, narrowed by the search.
    private var shown: [AcmeTicket] {
        search.isEmpty ? snapshot.tickets
            : snapshot.tickets.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private var content: some View {
        if shown.isEmpty {
            StateView(.empty(title: search.isEmpty ? "No tickets" : "Nothing matches", systemImage: "ticket", message: nil))
        } else {
            switch family {
            case .narrow: glance            // MetricView with the open count, then the top ticket
            case .wide: columns             // HStack of one column per status
            case .large:
                HStack(alignment: .top, spacing: 12) {
                    columns
                    triage.frame(minWidth: 140, maxWidth: 220)   // gives way to the columns
                }
            default: list                   // .medium: ItemRows, most urgent first
            }
        }
    }
}
```

Design each family for its size, don't shrink one:

- **narrow:** one number and one line. No columns or tables.
- **medium:** a list with a status dot, title and subtitle. `ItemRow` does this.
- **wide:** columns side by side.
- **large:** the wide layout plus a detail or insight area.

DashKitUI gives you `StateView` (empty, loading and failed states), `MetricView`, `ItemRow`,
`Badge`, `StatusDot` and `Tone` (`neutral`, `info`, `success`, `warning`, `danger`, `accent`).
Use them so your widget looks like the rest of Dash.

<details>
<summary>The whole <code>TicketsView.swift</code>: the four layouts, the header and the actions</summary>

```swift
import DashKit
import DashKitUI
import SwiftUI

struct TicketsView: View {
    let snapshot: TicketsSnapshot
    let family: WidgetLayout.Family
    @State private var search = ""

    private var shown: [AcmeTicket] {
        search.isEmpty ? snapshot.tickets
            : snapshot.tickets.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        content
            // In the card's header, not in the content: a count of what's shown (section 7).
            .widgetHeader { Badge("\(shown.filter { $0.status != "done" }.count) open", tone: shown.contains(where: \.isUrgent) ? .danger : .neutral) }
            // What Dashii may do while the widget is on screen (section 8).
            .handlesWidgetActions { name, input in
                guard name == "search" else { throw ToolError("Unknown action \(name).") }
                search = input["text"]?.string ?? ""
                return ["shown": .number(Double(shown.count))]
            }
            .reportsWidgetState(["search": .string(search)])
    }

    @ViewBuilder private var content: some View {
        if shown.isEmpty {
            StateView(.empty(title: search.isEmpty ? "No tickets" : "Nothing matches", systemImage: "ticket", message: nil))
        } else {
            switch family {
            case .narrow: glance
            case .wide: columns
            case .large:
                HStack(alignment: .top, spacing: 12) {
                    columns
                    triage.frame(minWidth: 140, maxWidth: 220)
                }
            default: list
            }
        }
    }

    private var glance: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricView("\(shown.filter { $0.status != "done" }.count)", label: "open tickets",
                       tone: shown.contains(where: \.isUrgent) ? .danger : .neutral)
            if let first = shown.first {
                Text(first.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(first.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { ticket in
                    ItemRow(ticket.title, subtitle: "\(ticket.id) · \(ticket.assignee ?? "Unassigned")",
                            leading: { StatusDot(Self.tone(ticket)) }, trailing: { Badge(ticket.status, tone: .neutral) })
                }
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 10) {
            // No empty "done" column when done tickets are hidden.
            ForEach(TicketsSnapshot.statuses.filter { $0 != "done" || shown.contains { $0.status == "done" } }, id: \.self) { status in
                let tickets = shown.filter { $0.status == status }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(status.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Badge("\(tickets.count)", tone: .neutral)
                    }
                    ForEach(tickets) { ticket in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ticket.title).font(.callout).lineLimit(2)
                            HStack {
                                Text(ticket.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                StatusDot(Self.tone(ticket), help: ticket.priority)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var triage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Triage", systemImage: "stethoscope").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(snapshot.triage ?? "The triage agent hasn't reported yet. Turn it on in Acme Board's AI tab.")
                .font(.callout)
                .foregroundStyle(snapshot.triage == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }

    static func tone(_ ticket: AcmeTicket) -> Tone {
        switch ticket.priority {
        case "urgent": .danger
        case "high": .warning
        default: .neutral
        }
    }
}

/// The sample at whatever size the gallery measures.
struct TicketsPreview: View {
    @Environment(\.widgetLayout) private var layout
    var body: some View { TicketsView(snapshot: .sample, family: layout.family) }
}
```

</details>

The preview at the end reads the family from the environment, because the gallery measures it
like a real card.

> **Checkpoint.** Run `scripts/try-plugin.sh AcmeBoard` and relaunch Dash. Acme Board's page in
> **Settings › Plugins** shows the preview with a size picker: check Small, Medium, Large and
> Wide. Then **Add Widget → Acme Tickets** and resize it through the four sizes. Each step
> should change the layout, not just stretch it. Stop the mock server: within a couple of
> minutes the widget keeps its tickets and shows a "stale" badge. Start it again: the badge goes
> at the next refresh.

## 7. The card header

Pickers, counts and "+" buttons belong in the card's title row, not inside the content where
they cost a row of space. The view's `body` puts the open count there with `.widgetHeader`:

```swift
content
    .widgetHeader {
        Badge("\(shown.filter { $0.status != "done" }.count) open", tone: shown.contains(where: \.isUrgent) ? .danger : .neutral)
    }
```

The card measures the header and keeps the title clear of it.

Don't anchor a popover to a header button. The header is rebuilt when data refreshes, which
closes the popover. Present a `.sheet` from the content view instead.

## 8. Let Dashii drive the widget

**Actions** are what Dashii may do to a widget on screen. They change what it shows (search,
filter, select), never data. Declare them in `TicketsWidget`:

```swift
static let actions = [
    WidgetAction(name: "search", description: "Show only tickets whose id or title contains the text. Empty clears it.",
                 properties: ["text": JSONSchema.string("Search text.")], required: ["text"]),
]
```

The visible view handles them and reports its UI state back. That's the rest of its `body`:

```swift
content
    .handlesWidgetActions { name, input in
        guard name == "search" else { throw ToolError("Unknown action \(name).") }
        search = input["text"]?.string ?? ""
        return ["shown": .number(Double(shown.count))]
    }
    .reportsWidgetState(["search": .string(search)])
```

`snapshot(config:context:)`, also in `TicketsWidget`, is what Dashii reads when it looks at the
widget ("what's on my Acme board?"):

```swift
static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
    guard let snapshot = try? await TicketsProvider(host: context.host).snapshot(for: config) else { return .null }
    return ["tickets": .array(snapshot.tickets.map(\.json)), "triage": snapshot.triage.map { .string($0) } ?? .null]
}
```

> **Checkpoint.** Rebuild and relaunch, then ask Dashii "show only the checkout tickets in Acme
> Tickets". The widget narrows to ACME-12 and the header says "1 open". Ask "clear the Acme
> search" to undo it.

## 9. Summaries by a smaller model

Reading a long list is a narrow job, and a smaller, cheaper model does it well. A
`DashiiFunction` is that job, typed: its input and output are Swift types, its answer is checked
against a schema, and it can be cached. Add it and a tool that uses it to `AcmeBoardTools`:

```swift
@MainActor
enum AcmeBoardTools {
    struct Summary: Codable, Sendable, Equatable { var summary: String }

    static let summary = DashiiFunction<[JSONValue], Summary>(
        name: "acme-board.summary", summary: "Summarize Acme tickets in two sentences.", task: "summary",
        instructions: "Summarize the tickets in two plain sentences: urgent work first, then what is in progress.",
        inputSchema: JSONSchema.array("Tickets.", of: JSONSchema.object(properties: ["title": JSONSchema.string(""), "status": JSONSchema.string("")],
                                                                        required: ["title", "status"])),
        outputSchema: JSONSchema.object(properties: ["summary": JSONSchema.string("")], required: ["summary"]),
        model: .fast, effort: .low, inputFormat: .compact, cacheFor: .seconds(600))

    static func tools(feature: AcmeBoardFeature) -> [DashiiTool] {
        [
            DashiiTool(name: "acme_board_tickets", description: "The Acme tickets Dash has: id, title, status, priority, assignee.") { [weak feature] _ in
                .array((feature?.tickets ?? []).map(\.json))
            },
            DashiiTool(name: "acme_board_summarize", description: "Summarize the open Acme tickets (a smaller model reads them).") { [weak feature] _ in
                guard let feature else { return nil }
                let host = try feature.requireHost()
                let open = feature.tickets.filter { $0.status != "done" }.map(\.json)
                let result = try await summary.run(open, dashii: host.dashii, settings: host.aiSettings(.extension(feature.id), tasks: feature.aiTasks))
                return .string(result.summary)
            },
        ]
    }
}
```

The feature lists the function and declares its **AI task**, so the user can pick its model and
effort in the plugin's **AI** tab:

```swift
var functions: [AnyDashiiFunction] { [AcmeBoardTools.summary.erased] }
var aiTasks: [AITask] {
    [AITask(id: "summary", title: "Summaries", summary: "Summarizes the open tickets.", models: [.fast, .balanced], defaultModel: .fast)]
}
```

Add a line to `Rules/acme-board.md`:

```markdown
- Summaries go through `acme_board_summarize`; say they come from a smaller model.
```

> **Checkpoint.** Rebuild and relaunch. Acme Board's **AI** tab lists *Summaries*. Ask Dashii
> "summarize my Acme tickets": it calls `acme_board_summarize`, and the answer says a smaller
> model wrote it.

## 10. Test it

Replace the scaffold's tests in `Tests/` with:

```swift
import DashKit
import DashKitTesting
import Foundation
import SwiftUI
import Testing

@MainActor
struct AcmeBoardFeatureTests {
    func make() throws -> (AcmeBoardFeature, TestHost) {
        let host = "acme-\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, routes: ["/tickets": #"[{"id":"ACME-1","title":"Checkout down","status":"doing","priority":"urgent"}]"#])
        let acme = TestIntegration(id: "acme", baseURL: URL(string: "https://\(host)")!)   // stands in for Tutorial 1
        let feature = AcmeBoardFeature()
        let dash = try TestHost([acme, feature])
        dash.start([acme, feature])
        return (feature, dash)
    }

    @Test func widgetLoadsThroughItsProvider() async throws {
        let (feature, dash) = try make()
        defer { feature.stop() }            // `start` began the refresh loop
        await feature.refresh()
        let loader = WidgetSnapshotLoader(provider: TicketsProvider(host: dash))
        await loader.load(.init())
        #expect(loader.snapshot?.tickets.map(\.id) == ["ACME-1"])
        #expect(WidgetType(TicketsWidget.self).preview != nil)
    }

    @Test func summariesGoToASmallerModel() async throws {
        let (feature, dash) = try make()
        defer { feature.stop() }
        await feature.refresh()
        dash.testDashii.reply = #"{"summary":"Checkout is down."}"#    // no real model in tests
        #expect(try await dash.runTool("acme_board_summarize") == "Checkout is down.")
        #expect(dash.testDashii.calls.last?.prompt.contains("Checkout down") == true)
    }
}
```

Keep the scaffold's `DefaultRulesTests.swift`: it checks every extension ships its rules.

- `TestIntegration` replaces the real integration, so the feature is tested on its own.
- `WidgetSnapshotLoader` runs a provider without a view.
- `testDashii` answers in place of the model, and records what it was asked.
- Keep the `TestHost` in a variable for the whole test: features hold their host weakly, so a
  discarded host means a feature that reads nothing.

> **Checkpoint.** `TEST=1 scripts/try-plugin.sh AcmeBoard` passes, with `TEST=1` again now that
> the scaffold's old tests are gone.

## Checklist

- [ ] `kind` is final, and `Config` fields are never renamed or removed. A new field needs a
      custom `init(from:)` using `decodeIfPresent`: synthesized `Codable` ignores default values,
      so widgets saved before the field existed would fail to decode.
- [ ] Each family has its own layout, and the narrow one fits 3 × 4 cells. Fixed widths give
      way (`minWidth`/`maxWidth`), since wide and large start at 480 points.
- [ ] The sample fills every layout; the preview touches nothing outside the plugin.
- [ ] Controls are in `.widgetHeader`; no popovers anchored there.
- [ ] Empty, loading and error states are handled (`StateView`, `ProvidedWidget`).
- [ ] `snapshot(config:context:)` tells Dashii what the widget shows.

## Going further

**DashQL.** A dataset lets Dashii (and users) query the tickets in one line, and lets users build
a widget from a query without code (`dash.data` widgets). Statements map words to your tools.
Put them back in `Sources/Query/AcmeBoardQuery.swift`:

```swift
import DashKit

extension AcmeBoardFeature {
    var datasets: [QueryDataset] {        // dashql: from acme_tickets where priority = "urgent"
        [QueryDataset(name: "acme_tickets", aliases: ["acme"], summary: "Acme tickets.",
                      fields: [.init("id", .string, "Ticket id"), .init("title", .string, "Title"),
                               .init("status", .string, "todo, doing or done"), .init("priority", .string, "low, normal, high or urgent"),
                               .init("assignee", .string, "Who works on it")]) { [weak self] _ in
            (self?.tickets ?? []).map(\.json)
        }]
    }

    var verbs: [DashQLVerb] {            // dashql: acme summarize
        [DashQLVerb("acme", "tickets", tool: "acme_board_tickets", summary: "List the tickets."),
         DashQLVerb("acme", "summarize", tool: "acme_board_summarize", summary: "Summarize the open tickets.")]
    }
}
```

Pick an alias that's yours (`acme`, not `tickets`): aliases are shared by every installed
extension, and the first one found wins. A test that every statement maps to a real tool:
`#expect(Set(feature.verbs.map(\.tool)).isSubset(of: Set(feature.tools.map(\.name))))`.

**Hook presets.** A watcher users turn on in one click: it runs a query on a schedule and fires
on new rows, with no AI involved:

```swift
var hookPresets: [HookPresetSpec] {
    [.appears("acme-board.urgent", "New urgent Acme ticket", dataset: "acme_tickets",
              where: "priority = \"urgent\" and status != \"done\"", key: "id",
              title: "Urgent: {{first.title}}", body: "{{first.id}}")]
}
```

**Data that survives a relaunch.** List `@Model` types in `models` and read and write them
through `host.context` (SwiftData, in Dash's database). The Debug window's **Database** pane
shows what's stored.

Next: [Tutorial 3: Build an agent](3-agent.md).
