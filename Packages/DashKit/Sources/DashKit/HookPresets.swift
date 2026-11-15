import Foundation

/// A ready-made hook an extension offers its users (and Dashii), shown under its category in
/// Settings › Automation › Hooks. Dash turns it into a hook only when the user (or Dashii, with
/// approval) picks it.
public struct HookPresetSpec: Sendable, Equatable, Identifiable {
    public enum Trigger: Sendable, Equatable {
        /// A watcher: Dash runs this DashQL query itself (no Claude) every `everyMinutes` and fires
        /// for rows it hasn't seen before, told apart by `key` (a field) or the whole row.
        case watch(query: String, everyMinutes: Int, key: String?)
        /// An activity event (`kind` may end with `*`).
        case event(kind: String, criticalOnly: Bool)
        /// Weekdays (1 Sunday … 7 Saturday) at "HH:mm".
        case schedule(time: String, weekdays: [Int])
    }

    public enum Action: Sendable, Equatable {
        /// A notification. Text takes {{count}}, {{rows}}, {{first.<field>}}, {{event.title}}…
        case notify(title: String, body: String)
        /// Wake a background agent with what was found; the user picks which agent.
        case wakeAgent(context: String)
        /// Ask Dashii, optionally saving the answer as a note.
        case ask(prompt: String, noteTitle: String?)
    }

    /// Stable, unique across extensions (prefix it with the extension id).
    public let id: String
    /// The group it shows in ("Cluster", "Pull requests"); nil uses the extension's name.
    public let category: String?
    public let name: String
    public let trigger: Trigger
    public let action: Action

    public init(id: String, category: String? = nil, name: String, trigger: Trigger, action: Action) {
        self.id = id
        self.category = category
        self.name = name
        self.trigger = trigger
        self.action = action
    }

    /// A watcher that notifies.
    public static func watch(_ id: String, category: String? = nil, _ name: String, query: String, every minutes: Int,
                             key: String?, title: String, body: String) -> HookPresetSpec {
        HookPresetSpec(id: id, category: category, name: name, trigger: .watch(query: query, everyMinutes: minutes, key: key),
                       action: .notify(title: title, body: body))
    }

    /// A watcher that wakes an agent with what it found.
    public static func wake(_ id: String, category: String? = nil, _ name: String, query: String, every minutes: Int,
                            key: String?, context: String) -> HookPresetSpec {
        HookPresetSpec(id: id, category: category, name: name, trigger: .watch(query: query, everyMinutes: minutes, key: key),
                       action: .wakeAgent(context: context))
    }
}

// MARK: - Templates

extension HookPresetSpec {
    /// Fires when rows matching `condition` appear in `dataset` (DashQL `where` syntax).
    public static func appears(_ id: String, category: String? = nil, _ name: String, dataset: String, where condition: String,
                               key: String?, every minutes: Int = 5, title: String, body: String) -> HookPresetSpec {
        watch(id, category: category, name, query: "from \(dataset) where \(condition)", every: minutes, key: key, title: title, body: body)
    }

    /// Fires when `field` goes over `limit` for a row (e.g. restarts over 5).
    public static func exceeds(_ id: String, category: String? = nil, _ name: String, dataset: String, field: String, over limit: Double,
                               key: String?, every minutes: Int = 5, title: String, body: String) -> HookPresetSpec {
        appears(id, category: category, name, dataset: dataset, where: "\(field) > \(Self.number(limit))", key: key, every: minutes, title: title, body: body)
    }

    /// Fires when a row reaches one of `values` in `field` (a status, a state).
    public static func reaches(_ id: String, category: String? = nil, _ name: String, dataset: String, field: String, values: [String],
                               key: String?, every minutes: Int = 5, title: String, body: String) -> HookPresetSpec {
        let list = values.map { "\"\($0)\"" }.joined(separator: ", ")
        return appears(id, category: category, name, dataset: dataset, where: "\(field) in (\(list))", key: key, every: minutes, title: title, body: body)
    }

    /// Fires for rows matching `condition` whose `dateField` is older than `age` (e.g. "-24h").
    public static func stale(_ id: String, category: String? = nil, _ name: String, dataset: String, where condition: String,
                             dateField: String, olderThan age: String, key: String?, every minutes: Int = 60, title: String, body: String) -> HookPresetSpec {
        appears(id, category: category, name, dataset: dataset, where: "(\(condition)) and \(dateField) < \(age)", key: key, every: minutes, title: title, body: body)
    }

    /// Wakes an agent when rows matching `condition` appear.
    public static func wakeOn(_ id: String, category: String? = nil, _ name: String, dataset: String, where condition: String,
                              key: String?, every minutes: Int = 5, task: String) -> HookPresetSpec {
        wake(id, category: category, name, query: "from \(dataset) where \(condition)", every: minutes, key: key,
             context: "{{count}} new:\n{{rows}}\n\(task)")
    }

    /// Notifies on an activity event.
    public static func onEvent(_ id: String, category: String? = nil, _ name: String, kind: String, criticalOnly: Bool = false) -> HookPresetSpec {
        HookPresetSpec(id: id, category: category, name: name, trigger: .event(kind: kind, criticalOnly: criticalOnly),
                       action: .notify(title: "{{event.title}}", body: "{{event.detail}}"))
    }

    private static func number(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
}

// MARK: - Library

/// Ready-made presets for the common datasets, built from the templates. A plugin that provides
/// a dataset offers them with one line: `HookPresetLibrary.presets(for: "pods", extension: id)`.
/// Ids are prefixed with the extension id, so two plugins offering the same dataset don't clash.
public enum HookPresetLibrary {
    /// The datasets this library has presets for.
    public static var datasets: [String] { ["pods", "monitors", "prs", "jira", "releases", "builds", "deploys", "workspaces", "containers", "blockers", "agents"] }

    public static func presets(for dataset: String, extension extensionID: String) -> [HookPresetSpec] {
        let p = { (name: String) in "\(extensionID).\(name)" }
        switch dataset {
        case "pods":
            return [
                .appears(p("pods-crashloop"), category: "Cluster", "Pods crash-looping", dataset: "pods", where: "status ~ crash or status ~ error",
                         key: "name", every: 2, title: "{{count}} pod(s) failing", body: "{{first.namespace}}/{{first.name}}: {{first.status}}"),
                .exceeds(p("pods-restarts"), category: "Cluster", "Pods restarting a lot", dataset: "pods", field: "restarts", over: 5,
                         key: "name", title: "{{first.name}} restarted {{first.restarts}} times", body: "{{first.namespace}} on {{first.node}}"),
                .appears(p("pods-not-ready"), category: "Cluster", "Pods not ready", dataset: "pods", where: "healthy = false and status !~ completed",
                         key: "name", title: "{{count}} pod(s) not ready", body: "{{first.namespace}}/{{first.name}}"),
                .reaches(p("pods-pending"), category: "Cluster", "Pods stuck pending", dataset: "pods", field: "status", values: ["Pending"],
                         key: "name", every: 10, title: "{{count}} pod(s) pending", body: "{{first.namespace}}/{{first.name}}"),
                .wakeOn(p("wake-crashloop"), category: "Wake an agent", "Investigate crash-looping pods", dataset: "pods",
                        where: "status ~ crash or restarts > 5", key: "name", every: 2, task: "Find the cause (logs, events, recent deploys) and report."),
            ]
        case "monitors":
            return [
                .reaches(p("monitors-alert"), category: "Monitoring", "Monitors alerting", dataset: "monitors", field: "status", values: ["Alert"],
                         key: "id", every: 2, title: "Alert: {{first.name}}", body: "{{count}} monitor(s) alerting"),
                .reaches(p("monitors-warn"), category: "Monitoring", "Monitors warning", dataset: "monitors", field: "status", values: ["Warn"],
                         key: "id", title: "Warning: {{first.name}}", body: "{{count}} monitor(s) warning"),
                .appears(p("monitors-nodata"), category: "Monitoring", "Monitors with no data", dataset: "monitors", where: "status ~ \"no data\"",
                         key: "id", every: 15, title: "No data: {{first.name}}", body: "A monitor stopped receiving data"),
                .wakeOn(p("wake-monitor"), category: "Wake an agent", "Investigate an alerting monitor", dataset: "monitors", where: "status = Alert",
                        key: "id", every: 2, task: "Correlate with pods, deploys and releases and report."),
            ]
        case "prs":
            return [
                .appears(p("prs-review-me"), category: "Pull requests", "A PR asks for my review", dataset: "prs", where: "review_requested = true",
                         key: "url", every: 10, title: "Review requested: {{first.title}}", body: "{{first.repo}}#{{first.number}} by {{first.author}}"),
                .appears(p("prs-high-risk"), category: "Pull requests", "High-risk PRs", dataset: "prs", where: "risk = high",
                         key: "url", every: 15, title: "High-risk PR: {{first.title}}", body: "{{first.repo}}#{{first.number}}"),
                .appears(p("prs-mine-approved"), category: "Pull requests", "My PR got approved", dataset: "prs", where: "mine = true and approvals > 0",
                         key: "url", every: 10, title: "Approved: {{first.title}}", body: "{{first.repo}}#{{first.number}}"),
                .appears(p("prs-mine-changes"), category: "Pull requests", "Changes requested on my PR", dataset: "prs", where: "mine = true and changes_requested = true",
                         key: "url", every: 10, title: "Changes requested: {{first.title}}", body: "{{first.repo}}#{{first.number}}"),
                .stale(p("prs-waiting"), category: "Pull requests", "PRs waiting on me for a day", dataset: "prs", where: "review_requested = true",
                       dateField: "updated", olderThan: "-24h", key: "url", title: "Still waiting on your review", body: "{{count}} PR(s), e.g. {{first.title}}"),
                .wakeOn(p("wake-review"), category: "Wake an agent", "Pre-review PRs asking for my review", dataset: "prs", where: "review_requested = true",
                        key: "url", every: 15, task: "Summarise each and flag risks."),
            ]
        case "jira":
            return [
                .appears(p("jira-assigned"), category: "Tickets", "A ticket is assigned to me", dataset: "jira", where: "assignee = me",
                         key: "key", every: 15, title: "Assigned: {{first.key}}", body: "{{first.summary}}"),
                .appears(p("jira-urgent"), category: "Tickets", "Urgent ticket not started", dataset: "jira",
                         where: "priority in (Highest, High, Critical, Blocker) and status_category = new and followed = true",
                         key: "key", every: 15, title: "Urgent: {{first.key}}", body: "{{first.summary}}"),
                .appears(p("jira-review"), category: "Tickets", "A followed ticket reaches review", dataset: "jira", where: "followed = true and status ~ review",
                         key: "key", every: 15, title: "In review: {{first.key}}", body: "{{first.summary}}"),
                .appears(p("jira-done"), category: "Tickets", "A followed ticket is done", dataset: "jira", where: "followed = true and status_category = done",
                         key: "key", every: 30, title: "Done: {{first.key}}", body: "{{first.summary}}"),
            ]
        case "releases":
            return [
                .appears(p("release-live"), category: "Releases & deploys", "A new release goes live", dataset: "releases", where: "live = true",
                         key: "id", every: 10, title: "Live: {{first.name}} ({{first.train}})", body: "{{first.new_commits}} new commit(s)"),
            ]
        case "builds":
            return [
                .appears(p("build-hotfix"), category: "Releases & deploys", "A hotfix build is cut", dataset: "builds", where: "hotfix = true",
                         key: "tag", every: 10, title: "Hotfix: {{first.tag}}", body: "{{first.subject}}"),
            ]
        case "deploys":
            return [
                .appears(p("deploy-failed"), category: "Releases & deploys", "A deploy fails", dataset: "deploys", where: "status ~ fail",
                         key: "at", title: "Deploy failed: {{first.app}} on {{first.workspace}}", body: "{{first.error}}"),
                .wakeOn(p("wake-deploy"), category: "Wake an agent", "Investigate a failed deploy", dataset: "deploys", where: "status ~ fail",
                        key: "at", task: "Find why and what to do."),
            ]
        case "workspaces":
            return [
                .appears(p("workspaces-cleanable"), category: "Workspaces & containers", "Workspaces ready to clean", dataset: "workspaces", where: "cleanable = true",
                         key: "name", every: 240, title: "{{count}} workspace(s) can be cleaned", body: "e.g. {{first.name}}: {{first.clean_reason}}"),
            ]
        case "containers":
            return [
                .appears(p("containers-exited"), category: "Workspaces & containers", "A container exits with an error", dataset: "containers",
                         where: "state = exited and exit_code != 0", key: "id", title: "{{first.name}} exited ({{first.exit_code}})", body: "{{first.image}}"),
                .reaches(p("containers-unhealthy"), category: "Workspaces & containers", "A container turns unhealthy", dataset: "containers", field: "health",
                         values: ["unhealthy"], key: "id", title: "Unhealthy: {{first.name}}", body: "{{first.image}}"),
            ]
        case "blockers":
            return [
                .appears(p("blockers-stuck"), category: "Standup & meetings", "A blocker is open for 2+ days", dataset: "blockers",
                         where: "open = true and days_open >= 2", key: "id", every: 240, title: "Blocker for {{first.days_open}} days", body: "{{first.text}}"),
            ]
        case "agents":
            return [
                .reaches(p("agents-failed"), category: "Standup & meetings", "A coding agent fails", dataset: "agents", field: "status", values: ["failed"],
                         key: "id", every: 10, title: "Agent failed on {{first.issue_key}}", body: "{{first.error}}"),
            ]
        default:
            return []
        }
    }

    /// Presets for every dataset an extension offers that the library knows.
    @MainActor
    public static func presets(for item: any DashExtension) -> [HookPresetSpec] {
        item.datasets.flatMap { presets(for: $0.name, extension: item.id) }
    }
}
