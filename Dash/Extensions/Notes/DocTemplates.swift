import DashKit
import Foundation

/// Documents Dashii writes into Notes from what Dash knows: the knowledge graph (code, tickets,
/// PRs, people, concepts), what it learned in conversations, the activity log, meetings and the
/// connected integrations. Each kind has a structure and the sources to gather it from; Dashii
/// gets them with `doc_template`, researches, then writes the note with `notes_create`.
enum DocKind: String, CaseIterable, Identifiable, Sendable {
    case howto, runbook, postmortem, bugReport = "bug_report", meetingNotes = "meeting_notes", dailyNote = "daily_note", serviceOverview = "service_overview", decision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .howto: "How-to"
        case .runbook: "Runbook"
        case .postmortem: "Postmortem"
        case .bugReport: "Bug Report"
        case .meetingNotes: "Meeting Notes"
        case .dailyNote: "Daily Note"
        case .serviceOverview: "Service Overview"
        case .decision: "Decision Record"
        }
    }

    var systemImage: String {
        switch self {
        case .howto: "list.number"
        case .runbook: "cross.case"
        case .postmortem: "flame"
        case .bugReport: "ladybug"
        case .meetingNotes: "person.3"
        case .dailyNote: "calendar"
        case .serviceOverview: "shippingbox"
        case .decision: "signpost.right.and.left"
        }
    }

    /// What the user is asked for before Dashii starts.
    var topicPrompt: String {
        switch self {
        case .howto: "Which task? e.g. add a localization key in PAPI"
        case .runbook: "Which symptom? e.g. gateway returns 528 for one backend"
        case .postmortem: "Which incident, and when?"
        case .bugReport: "What goes wrong, and where? e.g. papi-eu pods crash after the W43 release"
        case .meetingNotes: "Which meeting? Leave empty for the latest"
        case .dailyNote: "Which day? Leave empty for today"
        case .serviceOverview: "Which service or repository?"
        case .decision: "Which decision?"
        }
    }

    var titlePattern: String {
        switch self {
        case .howto: "How to <task>"
        case .runbook: "Runbook: <symptom>"
        case .postmortem: "Postmortem YYYY-MM-DD: <incident>"
        case .bugReport: "Bug: <component> — <observable symptom>"
        case .meetingNotes: "<Meeting> — YYYY-MM-DD"
        case .dailyNote: "Daily YYYY-MM-DD"
        case .serviceOverview: "<service>"
        case .decision: "Decision: <topic>"
        }
    }

    /// The outline to fill (Markdown headings with what goes under each).
    var outline: String {
        switch self {
        case .howto:
            """
            # How to <task>
            (a @Callout warning when older docs or Confluence pages are out of date, linking them)
            ## Where things live — table: what | where (repo paths, files, tools)
            ## Step by step — numbered ### steps, each with the exact commands and what their output means
            ## Using it — code snippets from the real code
            ## Gotchas — what bites people (from tickets, PRs, conversations)
            ## Checklist — - [ ] items to tick before done
            """
        case .runbook:
            """
            # Runbook: <symptom>
            **Symptom** — what the user sees, alerts that fire. **Severity hint** — when to page, when it can wait.
            ## Diagnose — numbered steps; each step a command or dashboard and a decision table (if X → go to step N)
            ## Fix — per cause, the fix and how to verify it
            ## Anti-patterns — what not to do and why
            ## Related — services, past postmortems, how-tos
            """
        case .postmortem:
            """
            # Postmortem YYYY-MM-DD: <incident>
            ## Impact — who and what was affected, for how long
            ## Timeline — table: time | event (from activity, alerts, PRs, deploys, messages)
            ## Root cause — the chain trigger → cause → symptom; confounders that misled
            ## Detection — how it was noticed, how it could be sooner
            ## Resolution — what fixed it
            ## Lessons
            ## Action items — - [ ] item, owner (proposals only: nothing is filed in Jira)
            """
        case .bugReport:
            """
            # Bug: <component> — <observable symptom>
            (title: what breaks where, as seen; never “it doesn't work”)
            **Severity** S1 critical (down, data loss, security) · S2 high (major feature broken, no workaround) · S3 medium (workaround exists) · S4 low (cosmetic) — with one line why.
            **Priority** P0–P3 (business urgency; may differ from severity) — say who decides.
            ## Environment — service and version/release, cluster/namespace or platform, region (EU/US), when it started
            ## Steps to reproduce — numbered, exact; preconditions and test data; what does NOT trigger it
            ## Expected result
            ## Actual result — what happens, with frequency (every time / 3 of 10)
            ## Impact — who is affected and how much
            ## Workaround — if any
            ## Evidence — the real log lines, metrics, pod statuses, request/response, release or deploy that introduced it (links, no secrets)
            ## Related — tickets, PRs, releases, past incidents
            One bug per report: if the evidence shows two problems, write two.
            """
        case .meetingNotes:
            """
            # <Meeting> — YYYY-MM-DD
            Attendees. Context in one line.
            ## Decisions
            ## Discussion — by topic, short
            ## Action items — - [ ] item, owner, due
            ## Open questions
            """
        case .dailyNote:
            """
            # Daily YYYY-MM-DD
            ## Done — PRs merged or opened, tickets moved, agents' work, releases (from activity and integrations)
            ## In progress — what's open and its next step
            ## Meetings — one line each, with decisions
            ## Blockers
            ## Tomorrow — the next steps
            """
        case .serviceOverview:
            """
            # <service>
            One paragraph: what it does and for whom.
            ## Architecture — a @Mermaid or table of its parts and what it talks to
            ## Repository layout — the main directories and what's in them
            ## Running and deploying — commands, environments, release trains
            ## Operations — dashboards, alerts, runbooks, owners
            ## Gotchas
            """
        case .decision:
            """
            # Decision: <topic>
            **Status** and date. **Deciders.**
            ## Context — the problem and the forces
            ## Options — each with pros and cons
            ## Decision — what and why
            ## Consequences — what changes, what to watch
            """
        }
    }

    /// Where the facts come from, in order.
    var sources: String {
        switch self {
        case .howto, .serviceOverview:
            "knowledge_search and knowledge_* tools (repos, files, symbols, concepts), memory_recall, notes_search for existing notes, Confluence/Jira read tools for older docs, git and code when a local checkout exists."
        case .runbook:
            "memory_recall and knowledge_search for the service, past incidents and fixes; the Kubernetes, GCP, Datadog and AWS read tools for the real commands and dashboards; notes_search for related runbooks."
        case .postmortem:
            "dashboard_activity over the incident window, Datadog/GCP logs and metrics, PRs and deploys around it, Jira tickets, meeting transcripts, memory_recall."
        case .bugReport:
            "dashql across pods, monitors and deploys (from pods where … ; from monitors where status = Alert; from deploys where at > -24h); the GCP and Datadog log and metric tools for the exact errors; releases and builds around when it started; jira and prs for duplicates and suspects; knowledge_search for the code involved; memory_recall."
        case .meetingNotes:
            "the meeting tools (transcript, speakers, summary), Jira tickets and PRs mentioned, memory_recall for context."
        case .dailyNote:
            "dashboard_activity for the day, the PR, Jira and agent tools, meetings of the day, the release timeline, memory_recall."
        case .decision:
            "the conversation so far, memory_recall, knowledge_search, related tickets, PRs and Confluence pages."
        }
    }

    var json: JSONValue {
        ["kind": .string(rawValue), "title_pattern": .string(titlePattern), "outline": .string(outline), "sources": .string(sources),
         "rules": .string(DocKind.rules)]
    }

    static let rules = """
        Only verified facts: every command, path and name comes from a tool result, not from memory of how \
        such things usually look. Say "unverified" where you could not check. Use the note components \
        (notes_components) where they help: callouts, tables, task lists. Link related notes with [[Title]] \
        and sources with Markdown links. No secrets (tokens, passwords, keys are never copied into a document). A bug \
        report is written to Notes only: never file it in Jira or post it anywhere; the user does that. Write it with notes_create (or notes_update if a note \
        with that title exists), then open it with view_show and say in one line what you wrote.
        """

    /// What's sent to the chat to start one.
    func prompt(topic: String) -> String {
        let subject = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let noun = title.lowercased().contains("note") ? title.lowercased() : title.lowercased() + " note"
        return "Write a \(noun)\(subject.isEmpty ? "" : " about: \(subject)"). Call doc_template with kind \(rawValue) first, gather the facts from its sources, then write it."
    }

    @MainActor
    static var tool: ClaudeTool {
        ClaudeTool(
            name: "doc_template",
            description: "The structure, sources and rules for a document you write into Notes from what Dash knows: how-to, runbook, postmortem, meeting notes, daily note, service overview or decision record. Call it before writing one.",
            properties: ["kind": JSONSchema.string("Document kind.", enum: allCases.map(\.rawValue))],
            required: ["kind"]
        ) { input in
            guard let raw = input["kind"]?.string, let kind = DocKind(rawValue: raw) else {
                throw ToolError("Kinds: \(allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return kind.json
        }
    }
}
