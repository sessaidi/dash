# Ingestor

A framework for bringing a service's data into Dash. An integration configures it: the client
(its connection, retries, rate limits), the routes to fetch and the mapper for each, the tables
the items land in, and what to keep fetched on a schedule. Ingestor does the rest: it fetches,
retries with backoff, pages, maps, cleans secrets out, stores the answer in Dash's database, fills
the tables, and gives Dashii readers, DashQL rows and SwiftUI feeds over what's stored. Neither
widgets nor Dashii call the service: only the ingestor does, when asked or on schedule.

It builds on DashKit (`DataFetcher`, `SyncedStore`, `Freshness`, `Sanitizer`). Plugins link it
statically; Dash.app provides DashKit, so Ingestor needs no Dash release.

## Routes and mappers

```swift
import DashKit
import Ingestor

extension AcmeIntegration {
    var ingestor: Ingestor {
        var ingestor = Ingestor(source: id, scope: "acme:" + site, store: host?.synced, maxAge: .seconds(15 * 60))
        ingestor.transform = { field, value in field == "key" ? value.uppercased() : value }
        if let connection { ingestor.client = IngestClient(connection: connection, service: "Acme", scope: ingestor.scope, store: host?.synced) }
        ingestor.notConnected = "Connect Acme in Settings."
        return ingestor
    }

    var resources: [IngestResource] {
        [
            IngestResource(kind: "acme.issue", reader: "acme_issue", summary: "One issue: summary, status, assignee.",
                           properties: ["key": JSONSchema.string("Issue key, e.g. KAN-123")], required: ["key"],
                           route: IngestRoute("/rest/api/3/issue/{key}", map: IngestMapper([
                               "key": "key", "summary": "fields.summary", "status": "fields.status.name",
                               "assignee": "fields.assignee.displayName", "labels": "fields.labels",
                           ]))),
            IngestResource(kind: "acme.search", reader: "acme_search", summary: "Issues matching a query.",
                           properties: ["jql": JSONSchema.string("The query.")], required: ["jql"], queryShaped: true,
                           route: IngestRoute("/rest/api/3/search/jql", query: ["jql": .input("jql"), "maxResults": "50"], items: "issues",
                                              paging: .token(field: "nextPageToken", parameter: "nextPageToken"),
                                              map: IngestMapper(["key": "key", "summary": "fields.summary"]))),
        ]
    }

    var fetchers: [DataFetcher] { Ingestor.fetchers(resources) { [weak self] in self?.ingestor } }
    var tools: [DashiiTool] { Ingestor.readers(resources) { [weak self] in self?.ingestor } }
}
```

A route is a path with `{field}` taken from the input (percent-encoded), query parameters
(`"50"`, `.input("state", default: "open")`, `.limit("limit", default: 15, max: 50)`,
`.compute { input in … }`), where the list is in the answer (`items: "issues"`), paging
(`.linkHeader`, `.token`, `.link`) and a limit (`.first(150)`, `.last(60)`). A mapper names the
fields to keep, each from a path: `"user.login"`, `"labels[].name"` (each element's name),
`"run_started_at|created_at"` (the first that isn't null), or `.path("draft", or: false)`,
`.exists("merged_at")`, `.prefix("head_sha", 7)`, `.firstLine("message")`,
`.list("files", fileMapper, limit: .first(150))`, `IngestField { item, input in … }` (nil leaves
the field out). `keep:` drops items; `.pluck("login")` makes each item one value. A resource can
also combine routes (`parts: ["": me, "organizations": orgs]`), or keep code of its own
(`IngestResource(…) { input in … }`) for answers that need it, such as text or decoding.

`data_fetch acme.issue {"key":"KAN-123"}` fetches the route and stores the mapped answer,
cleaned of secrets and capped at 200 KB, under kind `acme.issue`, keyed by the normalized
input. `acme_issue {"key":"KAN-123"}` returns it with `synced_at` and `stale`, or says what to
fetch. Answers to queries (`queryShaped: true`) are dropped after a day once their kind is stored
again.

`ingestor.rows(resources, stamp: ["repo"], id:)` gives a DashQL dataset its rows: every stored
item, with the input fields you stamp, `synced_at` and `stale`, the newest copy of each.

## Tables

An integration can also keep its own SwiftData tables, for what its widgets filter and sort
(pull requests, runs, issues). A row model adopts `IngestRow` and declares its typed fields; the
table's config says which resources fill it, what tells items apart, and how an item fills a row:

```swift
@Model final class AcmeIssue: IngestRow {
    var rowKey = ""
    var item = ""
    var syncedAt = Date.distantPast
    var key = ""
    var status = ""
    var updated: Date?
    init() {}
}

// At start:
database = try IngestDatabase(name: "acme", models: [AcmeIssue.self], folder: IngestDatabase.folder)
// In `ingestor`:
ingestor.database = database
ingestor.tables = [IngestTable(AcmeIssue.self, from: resources, id: "key") { row, item in
    row.key = item.string("key")
    row.status = item.string("status")
    row.updated = item.date("updated")
}]
try ingestor.syncTables()
```

`item.string`, `int`, `bool`, `date` and `strings` read a path with a default. A model can map
itself instead (`func update(from:)`) when the table gives no mapper.

After each fetch, the tables filled by that resource mirror the cache again: one row per item
(the newest copy), rows whose answers expired are deleted, and unchanged items aren't rewritten.
Widgets read them with `@Query` and `.modelContainer(database.container)`.

The tables live in the integration's own file, `~/Library/Application Support/Dash/Ingest/<name>.store`,
not in Dash's database. The cache stays the source of truth, so when a plugin update changes a
model in a way SwiftData can't migrate, the file is made again and rebuilt from the cache:
nothing is lost, and Dash's own data is never at risk.

### Features reading an integration's tables

A feature built on an integration (Pull Requests on GitHub) can read the integration's tables
directly:

1. The integration keeps its row models in a schema file of their own, with a version, and
   publishes its database in `exports`: `"database": {"name", "folder", "schema"}`.
2. The feature compiles that file too (in XcodeGen, `- path: ../GitHub/Schema` in its sources).
   Each plugin gets its own copy of the classes, named after its module, and SwiftData matches
   them to the same tables by name.
3. When the exported schema version is the one it was built with, the feature opens the file
   with `IngestDatabase.reading(name:models:folder:)`: read-only (a save fails), never migrated
   or replaced. On another version, or no file, it gets nil and reads through the readers.
4. `IngestRows` shows rows of a `FetchDescriptor`, reads them again whenever the integration
   stores, and asks the integration to fetch when nothing matches or they're stale:

```swift
let runs = IngestRows(database, FetchDescriptor<GitHubRun>(predicate: #Predicate { $0.branch == branch }),
                      host: host, fetcher: "github.workflow_runs", input: ["repo": .string(repo), "branch": .string(branch)])
await runs.load()   // runs.rows, runs.isFetching, runs.error
```

Only the integration writes its tables. A feature keeps its own state in its own models, and
anything new comes from the integration's fetchers.

## Background fetching

An integration can keep some resources fetched on a cycle, set by the user in its settings:

```swift
// In init:
schedule = IngestSchedule(prefix: "acme", defaults: defaults)
schedule.items = [
    IngestSyncItem(id: "issues", title: "Open issues", detail: "Of each watched project.", fetcher: "acme.issues",
                   defaultMinutes: 10) { [weak self] in (self?.projects ?? []).map { ["project": .string($0)] } },
    IngestSyncItem(id: "releases", title: "Releases", fetcher: "acme.releases", defaultMinutes: 60, defaultOn: false),
]
schedule.blocked = { [weak self] in self?.hasToken == true ? nil : "Add a token first." }
// start(host:): schedule.start(host: host)    stop(): schedule.stop()
// In the settings view:
IngestScheduleSection(schedule, footer: "…")
```

While Dash runs, each item that's on is fetched for each of its inputs once its interval has
passed, through the integration's own fetchers (so tables and widgets follow). The section offers
a switch for all background fetching, and per item a switch, an interval (1 minute to a day), when
it last ran or what failed, and Fetch Now. Choices and last runs are kept in `defaults` under
`<prefix>.sync.…`, so a restart doesn't fetch everything again. While `blocked` gives a reason
(no token, a used-up rate limit) nothing is fetched and the section says why; an item with no
inputs yet (nothing watched) runs as soon as it has some.

## Stored data

`ingestor.summary(resources)` counts the stored answers and gives the newest one's time;
`IngestDatabase.count(Row.self)` counts a table's rows. `ingestor.clear(resources)` deletes the
stored answers and the scope's ETags, then empties the tables, for a "Clear fetched data" button.
`ingestor.retention` sets how long answers to queries are kept.

## Requests

`IngestClient` makes the GET requests through the integration's `IntegrationConnection`, which
adds the auth headers. It's the ingestor's `client` for routes, and resources with code of their
own use it too (`json`, `text`, `fetch(route, input:)`):

- a request that failed for a passing reason (500, 502, 503, 504, 408, a timeout, a dropped
  network) is tried again after about 0.5 s, then 1 s, doubling up to `maxDelay` with some
  jitter: `client.retry = IngestRetry(attempts: 3, base: 0.5, maxDelay: 8)`, or `.none`;
  other errors (401, 404, 422…) aren't retried;
- it sends the last answer's ETag, and a 304 returns the stored copy (GitHub doesn't count those
  against the rate limit);
- after a rate-limit error (429, or a 403 saying so), or an answer with
  `X-RateLimit-Remaining: 0`, it stops calling that account until the limit resets and throws
  `IngestError.rateLimited`, while widgets keep showing what's stored;
- `pages(_:paging:)` follows `Link` headers, page tokens (`nextPageToken`) or links in the
  answer (`_links.next`).

## Widgets

```swift
struct IssueView: View {
    @State private var issue: IngestFeed

    init(host: any ExtensionContext, key: String) {
        _issue = State(initialValue: IngestFeed(host: host, fetcher: "acme.issue", reader: "acme_issue", input: ["key": .string(key)]))
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(issue.data?["summary"]?.string ?? "…")
            IngestStatus(issue)   // "Synced 3 min ago", the error, and a refresh button
        }
        .task { await issue.load() }
    }
}
```

The feed reads through the reader tool, so a plugin can show another integration's data without
knowing how it's stored. It fetches in the background when nothing is stored or it's stale (one
request for every feed showing the same thing), and re-reads whenever that fetcher stores again,
from any plugin.

## Test

```sh
swift test
```
