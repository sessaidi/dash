# Ingestor

Fetch into Dash, then read from Dash. An integration describes what it can fetch from its
service; Ingestor turns that into `data_fetch` fetchers that store the answer in Dash's database,
Dashii tools that read it back with its freshness, DashQL rows, and a SwiftUI feed that widgets
show. Neither widgets nor Dashii call the service: only fetchers do, when asked.

It builds on DashKit (`DataFetcher`, `SyncedStore`, `Freshness`, `Sanitizer`). Plugins link it
statically; Dash.app provides DashKit, so Ingestor needs no Dash release.

## Fetchers and readers

```swift
import DashKit
import Ingestor

extension AcmeIntegration {
    var ingestor: Ingestor {
        var ingestor = Ingestor(source: id, scope: "acme:" + site, store: host?.synced, maxAge: .seconds(15 * 60))
        ingestor.transform = { field, value in field == "key" ? value.uppercased() : value }
        return ingestor
    }

    var resources: [IngestResource] {
        [
            IngestResource(kind: "acme.issue", reader: "acme_issue", summary: "One issue: summary, status, assignee.",
                           properties: ["key": JSONSchema.string("Issue key, e.g. KAN-123")], required: ["key"]) { [weak self] input in
                guard let client = try self?.client else { throw ToolError("Acme isn't started.") }
                let issue = try await client.json("/rest/api/3/issue/" + (input["key"]?.string ?? ""))
                return ["key": issue["key"] ?? .null, "summary": issue["fields"]?["summary"] ?? .null]
            },
        ]
    }

    var fetchers: [DataFetcher] { Ingestor.fetchers(resources) { [weak self] in self?.ingestor } }
    var tools: [DashiiTool] { Ingestor.readers(resources) { [weak self] in self?.ingestor } }
}
```

`data_fetch acme.issue {"key":"KAN-123"}` calls the service and stores the compact answer,
cleaned of secrets and capped at 200 KB, under kind `acme.issue`, keyed by the normalized
input. `acme_issue {"key":"KAN-123"}` returns it with `synced_at` and `stale`, or says what to
fetch. Answers to queries (`queryShaped: true`) are dropped after a day once their kind is stored
again.

`ingestor.rows(resources, stamp: ["repo"], id:)` gives a DashQL dataset its rows: every stored
item, with the input fields you stamp, `synced_at` and `stale`, the newest copy of each.

## Requests

`IngestClient` makes a fetcher's GET requests through the integration's `IntegrationConnection`:

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
