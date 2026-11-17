# What the knowledge graph extracts

Dash indexes the repositories you add (Settings › Knowledge) into a local SQLite graph. Besides
files, symbols, imports, calls and git history, a set of extractors reads each file for what
it says about how the code runs and who it talks to. They're deterministic and local: no model
and no network, run on every changed file.

Dashii and agents read this graph; they never call external APIs to answer questions about
your code.

## Families

Ids without a repository in them are **shared**: a route served by one repository and called
from another is one node, and the same happens for topics, tables, hosts, flags, config keys,
images, owners and packages.

| Family | Read from | Node id | Main edges |
|---|---|---|---|
| Services | Dockerfiles, Helm charts, Kubernetes workloads, Go `cmd/<name>` mains, `package.json` start scripts, docker-compose | `service:<repo>:<name>` | `repo —deploys→ service`, `service —runs→ dir`, `service —defined_in→ file` |
| HTTP endpoints | Routes in Go (net/http, chi, gorilla/mux, gin, echo, fiber, httprouter, goji), Express, Koa, Fastify, Hono, NestJS, Next.js, Flask, FastAPI, Django, Vapor; OpenAPI 3 and Swagger 2 | `endpoint:<METHOD> <path>` (parameters as `{}`) | `endpoint —handled_by→ symbol`, `service —exposes→ endpoint` |
| Outbound calls | Go net/http and resty, fetch, axios, Angular `HttpClient`, ky, got, Python requests and httpx | `host:<name>` | `symbol —calls_endpoint→ endpoint`, `symbol —calls_host→ host` |
| gRPC | `.proto` services, rpcs, messages; Go, TS/JS and Python code registering or calling a service | `grpc:<pkg>.<Service>`, `proto:<pkg>.<Message>` | `symbol —implements→ rpc_service`, `symbol —calls_rpc→ rpc_service` |
| GraphQL | `.graphql` files and `gql` templates; gqlgen, Apollo and NestJS resolvers | `graphql:<Type>`, `graphql:Query.<field>` | `graphql_field —handled_by→ symbol` |
| Messaging | Kafka, Pub/Sub, SQS, SNS, NATS and RabbitMQ clients in Go, TS/JS and Python; Terraform; Strimzi and Config Connector manifests | `topic:<system>:<name>` | `symbol —publishes→ topic`, `symbol —consumes→ topic` |
| Databases | SQL migrations (replayed in order for the columns), Prisma, Django, SQLAlchemy, TypeORM and GORM models, SQL in string literals | `table:<schema>.<name>` | `file —migrates→ table`, `symbol —reads_table→ table`, `—writes_table→` |
| Workloads | Kubernetes manifests, Helm values (base and overlays merged), Terraform Kubernetes, Cloud Run and Helm resources | `workload:<repo>:<Kind>/<name>` | `service —deploys→ workload`, `workload —uses_image→ image`, `workload —sets_env→ env` |
| Images | Dockerfile `FROM` stages, compose `image:` | `image:<name>` | `file —uses_image→ image` |
| CI jobs | GitHub Actions, CircleCI, GitLab CI | `ci:<repo>:<workflow>/<job>` | `ci_job —deploys→ service` (or `—about→`) |
| Feature flags | LaunchDarkly, OpenFeature/flagd, Unleash, Split, Statsig, GrowthBook, ConfigCat SDK calls, flag wrappers and constants; flagd JSON | `flag:<key>` | `symbol —checks_flag→ flag` |
| Config keys | TOML, YAML and JSON config files; viper, koanf, node-config, Spring `@Value`, configparser, dynaconf; Go struct tags | `config:<dotted.key>` | `file —sets_config→ config`, `symbol —reads_config→ config` |
| Code owners | CODEOWNERS (`.github/`, root or `docs/`, as GitHub resolves it) | `owner:<@team, @user or email>` | `owner —owns→ repo, dir or file` (the fewest edges that say it) |
| Docs | The repository's Markdown, AsciiDoc and reST (not changelogs or licences) | `doc:repo:<root>/<path>` | `doc —documents→ dir`, `doc —about→ file, symbol, endpoint` |
| Dependencies | go.mod, package.json, requirements*.txt, pyproject.toml, Package.swift, Cargo.toml | `pkg:<language>:<name>` | `dir —depends_on→ pkg`, `repo —depends_on→ repo` |
| Tests | Go httptest, supertest and test clients in test files | (none) | `test —tests→ endpoint` |

## Linking across files and repositories

Edges one file can't make, such as a route's handler named in another file or the folder a
service runs, are kept as references and resolved once the repository is indexed. A second pass
then looks across repositories: calls to routes another repository defines (exact, or likely
matches with a lower weight), hosts named after a service, gRPC implementations and clients,
Pub/Sub subscriptions to their topics, table reads and writes, and package versions per
repository (`repo —depends_on→ repo` when one repository's module is another's dependency).

Re-indexing a file replaces exactly the edges it produced; shared nodes nothing points at any
more are dropped.

## What is never stored

Secret values. The extractors keep names: workloads list the environment variables, ConfigMaps
and Secrets they use, not their values; `.env` files give variable names; config files give keys,
never values; SQL keeps identifiers, not statements. CI steps and documents go through secret
masking before they're stored.

## Asking about it

Dashii's tools over the graph include:

- `knowledge_service_map`: one service end to end: what it exposes, who calls it, what it calls,
  topics, tables, flags, config, workloads, CI jobs, owners, docs and dependencies.
- `knowledge_endpoints`: routes by service, repository, path or method, with handler, callers
  and tests.
- `knowledge_owners`: who owns a path by CODEOWNERS (with who changed it most), or what an owner
  owns.
- `knowledge_search`, `knowledge_node`, `knowledge_context`, `knowledge_trace`, `knowledge_impact`
  and the rest for general questions.

DashQL datasets read the same data: `endpoints`, `topics`, `tables`, `flags` and `owners`, next to
`knowledge`. For example:

```text
from endpoints | where repo = "billing-api" and callers = 0
from tables | where readers ~ "Invoice" | select name, columns, migrations
from owners | count by owner
```

The Knowledge page shows the same relations, grouped: Exposes, Called by, Calls, Reads & writes,
Runs as, Owned by, Documented in, Tests.

## Cost

On four real repositories of different sizes, a first index with every extractor took about
1.2× as long as without them. Re-indexing an unchanged repository takes well under two seconds.
