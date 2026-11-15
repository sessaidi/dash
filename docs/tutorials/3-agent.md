# Tutorial 3: Build an agent

An **agent** is a specialist that works in the background. It runs on a schedule, when
something happens, or when Dashii hands it a question. Each run ends with a **report**: a
summary and findings with evidence. Dash stores reports, shows them, and turns serious findings
into activity events that hooks and notifications can act on.

You never talk to agents directly. You talk to **Dashii**, and Dashii delegates
("is checkout OK?" goes to the on-call SRE agent). Agents also run on their own and report back.

There are two ways to make one:

1. **No code:** ask Dashii, or use DashQL. Good for a personal watcher built from tools that
   already exist.
2. **In a plugin:** an `AgentDefinition`. Good when the agent ships with your data and tools,
   needs a free precheck, or should be shared through the Marketplace.

**Before you start:** finish [Tutorial 2](2-widget.md) (Acme and Acme Board installed, the mock
server running, Acme signed in to it). Agents run on Dashii's engine, so Dashii must work
(**Settings › Dashii**). The scripts and words used are in Tutorial 1's
[Before you start](1-integration.md#before-you-start).

## Part A: an agent without code

Tell Dashii what you want:

> Create an agent that checks my Acme tickets every hour and tells me about urgent ones nobody
> is working on.

Dashii turns that into a DashQL statement, which you can also type yourself:

```
agent create "Acme watcher" role="support lead" instructions="List the Acme tickets with acme_tickets; report urgent or high tickets that have no assignee or are still todo, most urgent first." integrations=[acme] every_minutes=60
```

Then manage it with:

```
agent "Acme watcher" run                              run it now
agent "Acme watcher" ask "anything urgent?"           a question; the report answers it
agent "Acme watcher" reports                          its recent reports
agent "Acme watcher" set every_minutes=30             change it
agent "Acme watcher" delete
```

You can call it by its name, as above, or by the id `agent create` returns. It's read-only by
default and can use every tool of the extensions you list in `integrations` (integrations or
features). Its model, effort, schedule and on/off switch are in **Settings › Automation ›
Agents**.

> **Checkpoint.** Create it, then `agent "Acme watcher" run`. The mock server prints
> `GET /tickets`, and the report lists ACME-15 if you made it urgent in Tutorial 1 (unassigned
> and todo), or says nothing needs attention. Delete it when you're done: Part B builds a better
> one into Acme Board.

## Part B: an agent in a plugin

This part adds a **Ticket triage** agent to the Acme Board feature from
[Tutorial 2](2-widget.md). The finished code is in
[`examples/AcmeBoard/Sources/Agents`](https://github.com/sessaidi/dash-registry/tree/main/examples/AcmeBoard/Sources/Agents).

### 1. Define it

**You add** three things. First, what the agent looks at, in `AcmeTicket`:

```swift
    /// Open and urgent or high: what the triage agent looks at.
    var needsTriage: Bool { (priority == "urgent" || priority == "high") && status != "done" }
```

Then the agent, in a new `Sources/Agents/AcmeAgents.swift`:

```swift
import DashKit

enum AcmeAgents {
    static let triage = AgentDefinition(
        id: "triage", name: "Ticket triage", summary: "Looks at urgent and high Acme tickets and says what to do first; read-only.",
        systemImage: "stethoscope", role: "support lead",
        specialities: ["ticket triage", "prioritisation"],
        instructions: """
            Look at the open Acme tickets with `acme_board_tickets`. For each urgent or high ticket: is someone on it, \
            is it blocked, what should happen next. Rank them. Use `acme_board_summarize` for a quick overview.
            In the report: the summary says what to do first; one finding per ticket that needs attention, critical \
            for urgent and unassigned, warning for urgent or high, info otherwise.
            """,
        tools: ["acme_board_tickets", "acme_board_summarize"],
        access: .readOnly,
        scope: "Acme tickets only; advise, never change a ticket.",
        schedule: AgentSchedule(everyMinutes: 60, events: ["acme.urgent"]),
        models: [.balanced, .fast, .strong], defaultModel: .balanced,
        precheck: { host in
            // Free: no model involved. Exactly what the instructions look at.
            let open = host.ext(AcmeBoardFeature.self)?.tickets.filter(\.needsTriage) ?? []
            return open.isEmpty ? .skip("No urgent or high ticket.")
                : .run(context: "Open now: " + open.map { "\($0.id) \($0.priority) \($0.title) (\($0.assignee ?? "unassigned"))" }.joined(separator: "; "))
        })
}
```

Last, list it in the feature:

```swift
var agents: [AgentDefinition] { [AcmeAgents.triage] }
```

Dash refers to it as `<extension id>.<agent id>`, here `acme-board.triage`.

> **Checkpoint.** Run `scripts/try-plugin.sh AcmeBoard` and relaunch Dash. Acme Board's **AI**
> tab (in **Settings › Plugins**) lists **Ticket triage**, turned off: plugin agents start off.
> Turn it on, then run `agent acme-board.triage run` in Dashii. The report ranks the open urgent
> and high tickets (ACME-12, ACME-9, and any you made urgent). Resize Acme Tickets to Large: the
> triage column shows the report's summary.

### 2. What each part does

**Who it is.** `role`, `specialities`, `instructions` and `scope` become the system prompt.
Write the instructions like a brief for a colleague:

- what to look at, and with which tools;
- how to judge what's wrong;
- what a good report looks like.

`scope` states its limits in plain words. The agent keeps to it and says so when asked to go
beyond.

**What it can use.** `tools` names tools from any installed extension. `integrations` grants
every tool of those extensions, so grant the fewest: `integrations: ["acme"]` would also give
the triage agent `acme_get`, any API path with the user's token, which it doesn't need.

**What it may do.** `access` has two values:

- `.readOnly` (the default) gives it only tools that read. Use it unless the agent must act.
- `.actWithApproval` also gives it tools marked `requiresApproval`. The user approves each
  call, in the same permission modal as Dashii's.

Tools marked `writesRemotely` are never given to an agent.

**The precheck.** `precheck` runs before any model is involved, so it costs no tokens. It
returns one of two values:

- `.skip("why")` records a skipped run.
- `.run(context: "what I saw")` runs, with that text added to the prompt.

An hourly agent whose precheck skips quiet hours costs almost nothing. Keep it in step with the
instructions: if they say "urgent or high" but the precheck only runs for urgent tickets, a day
with only high ones is skipped every hour. When Dashii asks the agent a question, the precheck
can't skip: what it saw becomes context for the answer.

**Model and cost.** `models` and `defaultModel` (`.fast`, `.balanced`, `.strong`, `.deep`)
appear in the plugin's **AI** tab, along with effort and the on/off switch. Heavy reading can go
to smaller models through `DashiiFunction`s, like `acme_board_summarize` from Tutorial 2.

### 3. Wake it when something happens

`AgentSchedule` has two triggers, and both can be set:

- `everyMinutes` runs it on a timer.
- `events` lists activity kinds that wake it.

With neither set, it runs only on demand. Any extension's event can wake your agent: an SRE
agent might wake on `datadog.alert` and `pod.crashloop`.

**You add** the event: the feature emits `acme.urgent` when it sees a new urgent ticket. In
`AcmeBoardFeature`, remember what was announced:

```swift
    /// Urgent tickets already announced, so a refresh only tells about new ones.
    @ObservationIgnored private var announced: Set<String> = []
```

And in `refresh()`, right after `lastError = nil`:

```swift
            // Checked after the await: two refreshes in flight mustn't announce the same ticket twice.
            let urgent = tickets.filter(\.isUrgent)
            for ticket in urgent where !announced.contains(ticket.id) {
                host?.activity.emit("acme.urgent", source: id, title: "Urgent: \(ticket.title)", detail: ticket.id, importance: .notable)
            }
            // Only the ones still urgent: one that stops being urgent and comes back is news again.
            announced = Set(urgent.map(\.id))
```

Emit once per new thing, not on every refresh: each event can wake agents and fire the user's
hooks. (This set starts empty at each launch; [Going further](#going-further) keeps it.)

> **Checkpoint.** Rebuild and relaunch. In `examples/MockAcme/tickets.json`, set ACME-17's
> priority to `"urgent"`. Within a minute, the Debug window's **Activity** pane shows
> "Urgent: Typo on the pricing page", and Ticket triage runs on its own. Its new report is in
> the Agents widget.

### 4. The report

Each run ends with a structured answer that Dash parses into an `AgentReport`:

- `summary`: one or two sentences, the answer.
- `findings`: each one has a `severity` (info, warning or critical), `title`, `detail` with the
  evidence, `target` (what it's about) and `suggestion`.
- `status`: `ok`, `findings`, `skipped` or `failed`.

Tell the agent in `instructions` how to grade severity for your domain, as above. Then:

- **warning** and **critical** findings become an `agent.finding` activity event. Users can hook
  it ("notify me", "create a note").
- Reports show in the Agents widget and Dashii's answers.
- Your own widget can show them: `host.agentReports("acme-board.triage", limit: 5)`. That's what
  the Acme Tickets provider does for its large layout.

### 5. Let Dashii delegate to it

Dashii sees every agent's name, role and specialities, and hands over questions in their field:

```
agent acme-board.triage ask "what should the team pick up first?"
```

Help it by saying so in your rules (`Rules/acme-board.md`):

```markdown
- For "what should I work on" questions, hand them to the triage agent (`agent acme-board.triage ask "…"`).
```

> **Checkpoint.** Rebuild and relaunch, then ask Dashii "what should I work on in Acme?". It
> hands the question to Ticket triage and answers with its report.

### 6. Test it

Test the precheck, the permissions and the event without a model. Add to
`AcmeBoardFeatureTests` (its `make()` is from Tutorial 2):

```swift
    @Test func triageSkipsWhenNothingNeedsIt() async throws {
        let (feature, dash) = try make()
        defer { feature.stop() }
        #expect(await AcmeAgents.triage.precheck?(dash) == .skip("No urgent or high ticket."))
        await feature.refresh()
        guard case .run(let context) = await AcmeAgents.triage.precheck?(dash) else { Issue.record("expected a run"); return }
        #expect(context.contains("ACME-1"))
        #expect(AcmeAgents.triage.allows(tool: "acme_board_tickets", from: "acme-board", requiresApproval: false))
        #expect(!AcmeAgents.triage.allows(tool: "acme_get", from: "acme", requiresApproval: false))
    }

    @Test func aNewUrgentTicketIsAnnouncedOnce() async throws {
        let (feature, dash) = try make()
        defer { feature.stop() }
        await feature.refresh()
        await feature.refresh()
        #expect(dash.activity.events.filter { $0.kind == "acme.urgent" }.count == 1)
    }
```

> **Checkpoint.** `TEST=1 scripts/try-plugin.sh AcmeBoard` passes. No test calls a model.

## Checklist

- [ ] Read-only unless it must act; `scope` says what it must not touch.
- [ ] `tools` and `integrations` list the minimum it needs.
- [ ] A precheck skips runs when there's nothing to look at, and runs for exactly what the
      instructions look at.
- [ ] Instructions say how to grade severity and what evidence to cite.
- [ ] Events that wake it are emitted once per new thing, not on every refresh.
- [ ] Tests cover the precheck and the tool permissions; no real model calls.

## Going further

**Announce once across relaunches.** The `announced` set above starts empty at each launch, so
the first refresh announces every open urgent ticket again, and wakes the agent for each. Keep
it in preferences instead (the example does), injectable so tests don't share it:

```swift
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var announced: Set<String> {
        get { Set(defaults.stringArray(forKey: "acme-board.announced") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "acme-board.announced") }
    }

    /// `defaults` is for tests; Dash uses the extensions' store.
    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
    }
```

Tests then give each feature its own suite,
`AcmeBoardFeature(defaults: UserDefaults(suiteName: "acme-board-tests-\(UUID().uuidString)")!)`,
and the example checks that two features on one suite announce a ticket once.

**What every agent can read.** On top of its `tools`, every agent gets a read-only base: DashQL
(`dash`, which reads every enabled extension's datasets), reading skills, and a few
`DashiiFunction`s. So `scope` is what keeps the agent on its subject; the tool list is what
keeps it from acting.

**Testing how a report is read.** Give `AgentReport.parse` an answer like the model's:

```swift
let report = try AgentReport.parse(#"{"summary":"ACME-1 first.","findings":[{"severity":"critical","title":"Checkout down","detail":"urgent, doing","target":"ACME-1","suggestion":"Page Ada"}]}"#,
                                   agentID: "acme-board.triage", startedAt: .now, reason: "manual")
#expect(report.status == .findings && report.severity == .critical)
```

**Built-in functions.** Agents and Dashii can also hand narrow jobs to a smaller model with
`function_run`: `logs.digest`, `rank`, `compare`, `root_cause`.

Back to [the plugin SDK reference](../PLUGINS.md).
