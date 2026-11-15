import DashKit
import Foundation

/// A question Dashii asks with answers to click (the page's role, what to show first…).
struct ChatChoices: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var question: String
    var options: [String]
    /// Several answers can be picked, then sent together.
    var multiple: Bool
    /// Also offer a free-text answer.
    var allowOther: Bool
    /// What the user answered, once they did.
    var answer: [String]?
}

/// Layouts Dashii proposes for a new page, drawn in the chat; the one picked is built.
struct LayoutProposal: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var pageName: String
    var icon: String
    var options: [LayoutOption]
    /// The option picked, once it was, and the page built from it.
    var chosen: String?
    var pageID: UUID?
}

struct LayoutOption: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var rationale: String
    var widgets: [ProposedWidget]
}

struct ProposedWidget: Codable, Equatable, Sendable {
    var kind: String
    var title: String
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var config: JSONValue?
}

extension ChatSession {
    /// Tools that draw components in the conversation.
    var componentTools: [ClaudeTool] {
        [
            ClaudeTool(
                name: "ask_user",
                description: """
                    Ask the user a question with answers to click, shown in the chat. Use it for choices (a page's role, \
                    which teams or services, what to see first). After calling it, end your turn: the answer arrives as \
                    the user's next message.
                    """,
                properties: [
                    "question": JSONSchema.string("The question, short."),
                    "options": ["type": "array", "items": ["type": "string"], "description": "2 to 8 short answers."],
                    "multiple": JSONSchema.boolean("Several answers can be picked (default false)."),
                    "allow_other": JSONSchema.boolean("Also offer a free-text answer (default true)."),
                ],
                required: ["question", "options"]
            ) { [weak self] input in
                guard let self else { return nil }
                let options = (input["options"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }
                guard let question = input["question"]?.string, (1...8).contains(options.count) else {
                    throw ToolError("Give a question and 1 to 8 options.")
                }
                let choices = ChatChoices(question: question, options: options, multiple: input["multiple"]?.bool ?? false,
                                          allowOther: input["allow_other"]?.bool ?? true)
                transcript.append(ChatEntry(id: choices.id, kind: .choices(choices)))
                return "Shown to the user. End your turn now; their answer comes as the next message."
            },
            ClaudeTool(
                name: "propose_layouts",
                description: """
                    Propose 2 or 3 layouts for a new dashboard page, drawn in the chat for the user to pick. Each option \
                    places configured widgets on the 12-column grid (x, y, w, h in cells; rows are 40 pt; respect each \
                    widget type's size limits from layout_context) with the config it needs (repos, namespaces, filters). \
                    Most important top-left. When the user picks one, Dash builds the page and tells you; then check the \
                    widgets' settings. After calling it, end your turn.
                    """,
                properties: [
                    "page_name": JSONSchema.string("The page's name, e.g. On-call."),
                    "icon": JSONSchema.string("SF Symbol name.", enum: DashboardStore.pageIcons),
                    "options": [
                        "type": "array", "description": "2 or 3 layouts.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"], "rationale": ["type": "string", "description": "One sentence: who it suits and why."],
                                "widgets": ["type": "array", "items": [
                                    "type": "object",
                                    "properties": ["kind": ["type": "string"], "title": ["type": "string"],
                                                   "x": ["type": "integer"], "y": ["type": "integer"], "w": ["type": "integer"], "h": ["type": "integer"],
                                                   "config": ["type": "object"]],
                                    "required": ["kind", "title", "x", "y", "w", "h"],
                                ]],
                            ],
                            "required": ["title", "rationale", "widgets"],
                        ],
                    ],
                ],
                required: ["page_name", "options"]
            ) { [weak self] input in
                guard let self else { return nil }
                let proposal = try layoutProposal(from: input)
                transcript.append(ChatEntry(id: proposal.id, kind: .layouts(proposal)))
                return .string("Drew \(proposal.options.count) layouts. End your turn now; the user's pick comes as the next message.")
            },
        ]
    }

    /// Checks a proposal against the installed widget types and their size limits.
    func layoutProposal(from input: JSONValue) throws -> LayoutProposal {
        guard let name = input["page_name"]?.string, !name.isEmpty else { throw ToolError("Name the page.") }
        let raw = input["options"]?.array ?? []
        guard (1...4).contains(raw.count) else { throw ToolError("Propose 2 or 3 layouts.") }
        var options: [LayoutOption] = []
        for (index, item) in raw.enumerated() {
            var widgets: [ProposedWidget] = []
            for entry in item["widgets"]?.array ?? [] {
                guard let kind = entry["kind"]?.string, let type = host.widgetType(kind) else {
                    throw ToolError("Unknown widget kind \(entry["kind"]?.string ?? "?"); see layout_context.")
                }
                let limits = type.sizeLimits
                let w = min(max(entry["w"]?.int ?? type.defaultSize.cells.w, limits.minW), min(limits.maxW, 12))
                let h = min(max(entry["h"]?.int ?? type.defaultSize.cells.h, limits.minH), limits.maxH)
                let config = try entry["config"].map { try type.normalize(type.defaultConfig.merging($0)) }
                widgets.append(ProposedWidget(kind: kind, title: entry["title"]?.string ?? type.displayName,
                                              x: min(max(entry["x"]?.int ?? 0, 0), 12 - w), y: max(entry["y"]?.int ?? 0, 0), w: w, h: h, config: config))
            }
            guard !widgets.isEmpty else { throw ToolError("Each layout needs widgets.") }
            options.append(LayoutOption(id: "option-\(index + 1)", title: item["title"]?.string ?? "Option \(index + 1)",
                                        rationale: item["rationale"]?.string ?? "", widgets: widgets))
        }
        let icon = input["icon"]?.string.flatMap { DashboardStore.pageIcons.contains($0) ? $0 : nil } ?? "square.grid.2x2"
        return LayoutProposal(pageName: name, icon: icon, options: options)
    }

    /// The user answered a question: recorded on the component and sent as their message.
    func answer(_ choicesID: String, with answers: [String]) {
        guard !answers.isEmpty, !isRunning,
              let index = transcript.lastIndex(where: { $0.id == choicesID }),
              case .choices(var choices) = transcript[index].kind, choices.answer == nil else { return }
        choices.answer = answers
        transcript[index].kind = .choices(choices)
        send(answers.joined(separator: ", "))
    }

    /// The user picked a layout: Dash builds the page, opens it, and tells Dashii to check it.
    func choose(_ optionID: String, in proposalID: String) {
        guard !isRunning, let index = transcript.lastIndex(where: { $0.id == proposalID }),
              case .layouts(var proposal) = transcript[index].kind, proposal.chosen == nil,
              let option = proposal.options.first(where: { $0.id == optionID }), let store = host.dashboard else { return }
        let page = store.createPage(name: proposal.pageName, systemImage: proposal.icon)
        var built: [String] = []
        for widget in option.widgets.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            guard let record = try? store.add(kind: widget.kind, title: widget.title, config: widget.config, page: page.id) else { continue }
            try? store.place(record.id, x: widget.x, y: widget.y, w: widget.w, h: widget.h, page: page.id)
            built.append("\(widget.title) [\(widget.kind), id \(record.id.uuidString)]")
        }
        proposal.chosen = optionID
        proposal.pageID = page.id
        transcript[index].kind = .layouts(proposal)
        host.selectedPageID = page.id
        host.mainView = "page"
        send("""
            I picked “\(option.title)”. Dash built the page “\(proposal.pageName)” (id \(page.id.uuidString)) with: \
            \(built.joined(separator: "; ")). Check each widget's settings (read_widget) and fix what's missing for me, \
            then tell me in a line or two what to set up myself.
            """)
    }
}
