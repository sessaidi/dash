import Foundation

/// A background agent an extension offers, e.g. an SRE agent that checks the clusters every
/// 15 minutes and reports what's wrong. Dash runs it with Dashii, giving it only the
/// tools it names, on its schedule or when one of its events happens, and stores each report
/// in the database. Widgets show reports with `host.agentReports(_:limit:)`; warning and
/// critical findings become activity events ("agent.finding") the user's hooks can act on.
///
/// ```swift
/// AgentDefinition(
///     id: "sre", name: "Cluster SRE", summary: "Watches pods and deployments.",
///     instructions: "You are an SRE. Check the pods; report crash loops, restarts and pending pods.",
///     tools: ["k8s_list_pods", "k8s_get"],
///     schedule: AgentSchedule(everyMinutes: 15, events: ["kubernetes.crashloop"]),
///     precheck: { host in
///         // Skip Dashii while everything is healthy.
///         unhealthy.isEmpty ? .skip("All pods healthy.") : .run(context: "Unhealthy: \(unhealthy)")
///     })
/// ```
public struct AgentDefinition: Sendable, Identifiable {
    /// Unique within the extension; Dash refers to it as "<extension id>.<id>".
    public let id: String
    public let name: String
    public let summary: String
    public let systemImage: String
    /// Its job title, e.g. "SRE", "Release manager", "Triage".
    public let role: String
    /// What it's good at, e.g. ["Kubernetes", "PostgreSQL", "incident response"].
    public let specialities: [String]
    /// What to look at and how: the core of each run's system prompt.
    public let instructions: String
    /// Dashii tools (from any installed extension) it may call by name…
    public let tools: [String]
    /// …and every tool of these extensions (integrations or features, by id).
    public let integrations: [String]
    /// Whether it may use tools that change things (each use still asks the user).
    public let access: AgentAccess
    /// Limits it must respect, in plain words: "only the prod namespace", "repos in acme/*".
    public let scope: String
    public let schedule: AgentSchedule
    /// Model, effort and on/off, configurable in the extension's AI tab.
    public let task: AITask
    /// A cheap check before involving Dashii (no tokens): skip the run, or run with context.
    public let precheck: (@MainActor @Sendable (any ExtensionContext) async -> AgentPrecheck)?

    public init(id: String, name: String, summary: String, systemImage: String = "person.badge.shield.checkmark",
                role: String = "", specialities: [String] = [],
                instructions: String, tools: [String] = [], integrations: [String] = [], access: AgentAccess = .readOnly,
                scope: String = "", schedule: AgentSchedule = AgentSchedule(),
                models: [DashiiModel] = [.balanced, .fast, .strong], defaultModel: DashiiModel = .balanced,
                enabledByDefault: Bool = false,
                precheck: (@MainActor @Sendable (any ExtensionContext) async -> AgentPrecheck)? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.systemImage = systemImage
        self.role = role
        self.specialities = specialities
        self.instructions = instructions
        self.tools = tools
        self.integrations = integrations
        self.access = access
        self.scope = scope
        self.schedule = schedule
        self.task = AITask(id: "agent.\(id)", title: name, summary: summary, models: models, defaultModel: defaultModel,
                           efforts: [.low, .medium, .high], defaultEffort: .medium, enabledByDefault: enabledByDefault)
        self.precheck = precheck
    }
}

extension AgentDefinition {
    /// The system prompt: role, specialities, instructions and scope.
    public var systemPrompt: String {
        var text = role.isEmpty ? "You are \(name)." : "You are \(name), a \(role)."
        if !specialities.isEmpty { text += " Your specialities: \(specialities.joined(separator: ", "))." }
        text += "\n\n" + instructions
        if !scope.isEmpty { text += "\n\nScope — stay within it and say so when asked to go beyond: \(scope)" }
        if access == .readOnly { text += "\n\nYou are read-only: observe and report, never change anything." }
        return text
    }

    /// The tools it may use among `available` (name and owning extension id, whether it changes things).
    public func allows(tool name: String, from extensionID: String, requiresApproval: Bool) -> Bool {
        guard tools.contains(name) || integrations.contains(extensionID) else { return false }
        return access == .actWithApproval || !requiresApproval
    }
}

public enum AgentAccess: String, Sendable, Codable, CaseIterable {
    /// Only tools that read.
    case readOnly
    /// Also tools that change things; the user approves each call.
    case actWithApproval
}

/// When an agent runs on its own. Both can be set; neither means only on demand.
public struct AgentSchedule: Sendable, Hashable, Codable {
    public var everyMinutes: Int?
    /// Activity event kinds that start a run (e.g. "pr.opened", "kubernetes.crashloop").
    public var events: [String]

    public init(everyMinutes: Int? = nil, events: [String] = []) {
        self.everyMinutes = everyMinutes
        self.events = events
    }
}

public enum AgentPrecheck: Sendable, Equatable {
    /// Nothing to look at: record a skipped run with this note, without calling Dashii.
    case skip(String)
    /// Run, with this text added to the prompt (what the check saw).
    case run(context: String)
}

public struct AgentFinding: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case info, warning, critical
        public static func < (a: Severity, b: Severity) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public var severity: Severity
    public var title: String
    public var detail: String
    /// What it's about: a pod, a service, a PR…
    public var target: String
    /// What to do about it; empty when nothing.
    public var suggestion: String

    public var id: String { "\(severity.rawValue)|\(target)|\(title)" }

    public init(severity: Severity, title: String, detail: String = "", target: String = "", suggestion: String = "") {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.target = target
        self.suggestion = suggestion
    }
}

/// One run of an agent.
public struct AgentReport: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Ran and found nothing worth reporting.
        case ok
        /// Ran and reported findings.
        case findings
        /// The precheck said there was nothing to look at.
        case skipped
        case failed
    }

    public var id: UUID
    /// "<extension id>.<agent id>"
    public var agentID: String
    public var startedAt: Date
    public var finishedAt: Date
    /// Why it ran: "schedule", "manual", or the event kind.
    public var reason: String
    public var status: Status
    public var summary: String
    public var findings: [AgentFinding]
    public var costUSD: Double

    public init(id: UUID = UUID(), agentID: String, startedAt: Date, finishedAt: Date = .now, reason: String, status: Status,
                summary: String, findings: [AgentFinding] = [], costUSD: Double = 0) {
        self.id = id
        self.agentID = agentID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.reason = reason
        self.status = status
        self.summary = summary
        self.findings = findings
        self.costUSD = costUSD
    }

    /// The most severe finding's severity.
    public var severity: AgentFinding.Severity? { findings.map(\.severity).max() }

    /// The JSON schema of the report Dashii returns at the end of a run.
    public static let outputSchema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "required": ["summary", "findings"],
        "properties": [
            "summary": ["type": "string", "description": "One or two sentences: what was checked and the overall state."],
            "findings": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["severity", "title", "detail", "target", "suggestion"],
                    "properties": [
                        "severity": ["type": "string", "enum": ["info", "warning", "critical"]],
                        "title": ["type": "string"],
                        "detail": ["type": "string", "description": "What was observed, with the evidence."],
                        "target": ["type": "string", "description": "What it is about (pod, service, PR, ticket…)."],
                        "suggestion": ["type": "string", "description": "What to do; empty if nothing."],
                    ],
                ],
            ],
        ],
    ]

    /// Builds a report from Dashii's structured answer.
    public static func parse(_ text: String, agentID: String, startedAt: Date, reason: String, costUSD: Double = 0) throws -> AgentReport {
        let json = try JSONValue.parse(text)
        // Each finding on its own: one malformed finding mustn't hide the others or read as "all good".
        let raw = json["findings"]?.array ?? []
        let findings = raw.compactMap { try? $0.decode(AgentFinding.self) }
        if !raw.isEmpty, findings.isEmpty {
            return AgentReport(agentID: agentID, startedAt: startedAt, reason: reason, status: .failed,
                               summary: "The agent reported findings Dash couldn't read.", findings: [], costUSD: costUSD)
        }
        return AgentReport(agentID: agentID, startedAt: startedAt, reason: reason, status: findings.isEmpty ? .ok : .findings,
                           summary: json["summary"]?.string ?? "", findings: findings, costUSD: costUSD)
    }
}
