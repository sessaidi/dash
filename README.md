# Dash

A native macOS (SwiftUI, macOS 26+) work dashboard with Claude built in.

- **Jira**: your board's columns (active sprint for scrum boards) and the issues you follow; comment, transition, start an agent.
- **GitHub**: open PRs on the repositories you watch, polled with ETags. Each new head commit gets an automatic Claude review in a fixed structure (verdict, risk, findings with file:line, testing). Comment, approve, request changes, merge, or post Claude's review.
- **Agents**: from a Jira ticket, Dash creates a git worktree and branch, then runs Claude Code in it. First you discuss a plan (plan mode), then it implements with extreme TDD, committing each green step. Dash pushes and opens a draft PR when you click Create PR.
- **Zoom**: captures Zoom's audio and your mic with ScreenCaptureKit, transcribes on-device with SpeechAnalyzer, reads the participant list through Accessibility, and summarises with Claude when the meeting ends.
- **Marketplace**: installs integrations and features from git repositories that act as registries.
- **Claude panel** (⌘K): a streaming chat that can call every extension's tools. It runs on **Claude Code with your Claude login** (Dash's tools are served to it as an in-process MCP server); there is no API-key mode. Anything that writes or deletes asks first in a modal.

Everything is stored in SwiftData at `~/Library/Application Support/Dash/Dash.store`; tokens are kept in the Keychain.

## Build

```sh
brew install xcodegen
xcodegen generate
open Dash.xcodeproj          # or:
xcodebuild -scheme Dash -derivedDataPath build/DerivedData test
```

Then fill in Settings: Claude Code must be installed and logged in (`claude /login`) — no API key needed; your Jira site, email and API token, a GitHub fine-grained PAT plus the repos to watch, and the Jira project → local repo mapping for Agents.

## Layout

| Path | What |
|---|---|
| `Dash/Core` | Extension host, plugin loading (at launch and hot install), SwiftData dashboard store, permission center |
| `Dash/Claude` | Messages API client (raw HTTP + SSE), stream accumulator, chat agent loop, dashboard tools |
| `Dash/Extensions/*` | What ships in the app: Basics (Note, World Clock) and the Marketplace. Every integration and feature is a plugin in [dash-registry](~/code/dash-registry), installed from Settings › Marketplace (see docs/PLUGINS.md) |
| `Examples/Registry` | Template registry repo (marketplace) with example integrations and features |
| `Packages/ClaudeCodeKit` | Swift library for the Claude Code CLI, modelled on the Agent SDK: `query()`, `ClaudeCodeSession`, typed messages, `canUseTool`, interrupt |
| `docs/PLUGINS.md` | The plugin SDK: writing, testing and publishing `.dashplugin` extensions |
