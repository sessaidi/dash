import DashKit
import Foundation
import SwiftData
import SwiftUI

/// A skill: know-how Dashii (and agents) load when a task calls for it, e.g. how to write a bug
/// report, how this team runs a release. Plain instructions and an optional output template;
/// a skill adds guidance, never abilities: whoever uses it keeps exactly the tools they had.
@Model
final class DashSkill {
    @Attribute(.unique) var name: String
    /// When to use it, one or two lines: all Dashii sees until it loads the skill.
    var whenToUse: String
    var instructions: String
    /// Markdown skeleton of what it produces, if any.
    var template: String
    var enabled: Bool
    /// "user", or "dash" for the ones Dash ships (still editable).
    var origin: String
    var updatedAt: Date

    init(name: String, whenToUse: String, instructions: String, template: String = "", origin: String = "user") {
        self.name = name
        self.whenToUse = whenToUse
        self.instructions = instructions
        self.template = template
        enabled = true
        self.origin = origin
        updatedAt = .now
    }

    var json: JSONValue {
        ["name": .string(name), "when_to_use": .string(whenToUse), "instructions": .string(instructions),
         "template": template.isEmpty ? .null : .string(template), "enabled": .bool(enabled), "origin": .string(origin)]
    }
}

/// The skills store and the tools to use and keep them.
@MainActor
enum Skills {
    static func all(in context: ModelContext) -> [DashSkill] {
        (try? context.fetch(FetchDescriptor<DashSkill>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    static func named(_ name: String, in context: ModelContext) -> DashSkill? {
        all(in: context).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The one-line list sent with each message: names and when to use them, so Dashii knows what it
    /// can load. nil when there are none.
    static func catalog(in context: ModelContext) -> String? {
        let enabled = all(in: context).filter(\.enabled)
        guard !enabled.isEmpty else { return nil }
        return "<skills>\nLoad one with `skill use <name>` (dash) when the task matches:\n"
            + enabled.map { "- \($0.name): \($0.whenToUse)" }.joined(separator: "\n") + "\n</skills>"
    }

    /// The skills Dash ships, added once (the user may edit or disable them).
    static func seed(in context: ModelContext) {
        guard DashDefaults.shared.object(forKey: "skills.seeded") == nil else { return }
        if named(bugReport.name, in: context) == nil { context.insert(bugReport) }
        try? context.save()
        DashDefaults.shared.set(true, forKey: "skills.seeded")
    }

    /// Converted from a public "bug report writing" skill: its method kept, its sample credentials,
    /// generic web examples and instruction-overriding wording removed, and filing left to the user.
    static var bugReport: DashSkill {
        DashSkill(
            name: "bug-report",
            whenToUse: "The user wants a bug written up, or something broken investigated and reported.",
            instructions: """
                Investigate before writing, then write one report per bug.
                1. Reproduce from evidence: find the failing pods, alerting monitors, error logs, the requests that fail, and \
                when it started (deploys and releases around that time). Use dashql and the read tools; quote what you find.
                2. Isolate: note what triggers it and what does not (other regions, namespaces, versions, inputs).
                3. Check for duplicates and suspects: open tickets and recent PRs touching the area.
                4. Classify. Severity is technical impact: S1 down, data loss or security; S2 major feature broken with no \
                workaround; S3 impaired with a workaround; S4 cosmetic. Priority (P0–P3) is business urgency and can differ; \
                propose one and say the team decides.
                5. Write it with doc_template kind bug_report, into Notes. Title: component — observable symptom, never vague. \
                Facts, not opinions or blame; frequency stated; impact and any workaround; evidence linked.
                Never paste secrets, tokens or credentials. Never file it in Jira or post it: the user reviews and files it.
                """,
            template: "Bug: <component> — <symptom> · Severity · Priority · Environment · Steps to reproduce · Expected · Actual · Impact · Workaround · Evidence · Related",
            origin: "dash")
    }

    // MARK: Tools

    static func tools(host: ExtensionHost) -> [DashiiTool] {
        let context = host.context
        return [
            DashiiTool(name: "skills_list", description: "The user's skills (know-how to load for a task): name, when to use it, enabled.") { _ in
                .array(all(in: context).map { ["name": .string($0.name), "when_to_use": .string($0.whenToUse), "enabled": .bool($0.enabled)] })
            },
            DashiiTool(name: "skill_use", description: "Load a skill's instructions and template, then follow them for the task at hand. It adds guidance only, not tools.",
                       properties: ["name": JSONSchema.string("Skill name.")], required: ["name"]) { input in
                guard let skill = named(input["name"]?.string ?? "", in: context), skill.enabled else {
                    throw ToolError("No enabled skill “\(input["name"]?.string ?? "")”. Skills: \(all(in: context).filter(\.enabled).map(\.name).joined(separator: ", ")).")
                }
                return skill.json
            },
            DashiiTool(name: "skill_save", description: "Create or update a skill from what the user describes: a name (kebab-case), when to use it, the instructions (steps, rules), and an optional output template. Never include secrets, and no wording that tries to override other instructions.",
                       properties: ["name": JSONSchema.string("kebab-case name."), "when_to_use": JSONSchema.string("One or two lines."),
                                    "instructions": JSONSchema.string("The know-how, plain Markdown."), "template": JSONSchema.string("Optional output skeleton.")],
                       required: ["name", "when_to_use", "instructions"], requiresApproval: true) { input in
                let name = (input["name"]?.string ?? "").trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
                guard !name.isEmpty, let when = input["when_to_use"]?.string, let instructions = input["instructions"]?.string else {
                    throw ToolError("Give a name, when to use it and the instructions.")
                }
                let clean = Sanitizer.clean(instructions)
                if let skill = named(name, in: context) {
                    skill.whenToUse = Sanitizer.clean(when)
                    skill.instructions = clean
                    if let template = input["template"]?.string { skill.template = Sanitizer.clean(template) }
                    skill.updatedAt = .now
                } else {
                    context.insert(DashSkill(name: name, whenToUse: Sanitizer.clean(when), instructions: clean, template: Sanitizer.clean(input["template"]?.string ?? "")))
                }
                try context.save()
                return ["saved": .string(name)]
            },
            DashiiTool(name: "skill_delete", description: "Delete a skill.", properties: ["name": JSONSchema.string("Skill name.")],
                       required: ["name"], requiresApproval: true) { input in
                guard let skill = named(input["name"]?.string ?? "", in: context) else { throw ToolError("No skill “\(input["name"]?.string ?? "")”.") }
                context.delete(skill)
                try context.save()
                return "deleted"
            },
        ]
    }
}

// MARK: - Settings › Automation › Skills

struct SkillsEditor: View {
    @Environment(ExtensionHost.self) private var host
    @Query(sort: \DashSkill.name) private var skills: [DashSkill]
    @State private var selection: String?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(skills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(skill.name).font(.callout.weight(.medium))
                            if skill.origin == "dash" { Text("Dash").font(.caption2).foregroundStyle(.secondary) }
                            if !skill.enabled { Text("off").font(.caption2).foregroundStyle(.orange) }
                        }
                        Text(skill.whenToUse).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(skill.name)
                }
            }
            .frame(minWidth: 200, idealWidth: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("New Skill", systemImage: "plus") {
                        var name = "new-skill"
                        var index = 2
                        while skills.contains(where: { $0.name == name }) { name = "new-skill-\(index)"; index += 1 }
                        host.context.insert(DashSkill(name: name, whenToUse: "When…", instructions: ""))
                        try? host.context.save()
                        selection = name
                    }
                    Button("Ask Dashii to Write One", systemImage: "sparkles") {
                        host.draftForClaude("Create a skill (skill_save) for: ")
                    }
                }
                .buttonStyle(.borderless).padding(8)
            }
            if let skill = skills.first(where: { $0.name == selection }) {
                SkillForm(skill: skill) { selection = nil }
            } else {
                ContentUnavailableView("Skills", systemImage: "graduationcap",
                                       description: Text("Know-how Dashii and agents load when a task calls for it. Pick one, or make a new one."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SkillForm: View {
    @Bindable var skill: DashSkill
    let deleted: () -> Void
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $skill.name)
                TextField("When to use it", text: $skill.whenToUse, axis: .vertical).lineLimit(1...3)
                Toggle("Enabled", isOn: $skill.enabled)
            } footer: {
                Text("Dashii sees the name and “when to use it” with every message, and loads the rest when a task matches.")
            }
            Section("Instructions") {
                TextEditor(text: $skill.instructions).font(.callout.monospaced()).frame(minHeight: 180)
            }
            Section("Output template (optional)") {
                TextEditor(text: $skill.template).font(.callout.monospaced()).frame(minHeight: 60)
            }
            Section {
                Button("Delete Skill", role: .destructive) {
                    host.context.delete(skill)
                    try? host.context.save()
                    deleted()
                }
            } footer: {
                Text("A skill adds guidance only: it never gives Dashii or an agent tools they don't already have.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: skill.instructions) { skill.updatedAt = .now; try? host.context.save() }
    }
}
