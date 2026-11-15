import DashKit
import DashKitUI
import Foundation

/// Tools for reading and arranging the dashboard itself.
@MainActor
enum CoreTools {
    private struct WidgetID: Decodable { let id: String }
    private struct AddInput: Decodable { let kind: String; let title: String?; let size: WidgetSize?; let config: JSONValue?; let page_id: String? }
    private struct UpdateInput: Decodable { let id: String; let title: String?; let size: WidgetSize?; let config: JSONValue? }
    private struct ActivityInput: Decodable { let minutes: Int?; let source: String?; let important_only: Bool? }
    private struct PlaceInput: Decodable { let id: String; let x: Int?; let y: Int?; let w: Int?; let h: Int?; let page_id: String? }
    private struct PageInput: Decodable { let name: String; let icon: String? }
    private struct PageUpdateInput: Decodable { let id: String; let name: String?; let icon: String? }
    private struct PageIDInput: Decodable { let id: String }
    private struct ListInput: Decodable { let page_id: String? }
    private struct DraftInput: Decodable { let name: String; let icon: String?; let rationale: String }
    private struct ActInput: Decodable { let id: String; let action: String; let input: JSONValue? }

    private static func uuid(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw ToolError("\"\(text)\" is not an id. Call list_widgets or list_pages.") }
        return id
    }

    static func tools(host: ExtensionHost) -> [ClaudeTool] {
        let store = host.dashboard!
        let sizes = WidgetSize.allCases.map(\.rawValue)
        return [
            ClaudeTool(
                name: "dashboard_activity",
                description: "The dashboard's activity log: new and reviewed PRs, ticket moves, agent progress, meetings, workspace and layout changes. Use it to answer \"what happened\" questions or to look further back than the per-turn summary.",
                properties: [
                    "minutes": JSONSchema.integer("How far back to look (default 120)."),
                    "source": JSONSchema.string("Only events from this extension id, e.g. pull-requests."),
                    "important_only": JSONSchema.boolean("Only notable and critical events."),
                ]
            ) { input in
                let request = try input.toolInput(ActivityInput.self)
                let events = host.activity.events(since: Date().addingTimeInterval(-Double(request.minutes ?? 120) * 60), source: request.source,
                                                  minimum: request.important_only == true ? .notable : .info)
                return .array(events.suffix(200).map {
                    ["time": .string($0.date.formatted(.iso8601)), "source": .string($0.source), "kind": .string($0.kind), "title": .string($0.title),
                     "detail": $0.detail.map(JSONValue.string) ?? .null, "link": $0.link.map(JSONValue.string) ?? .null, "importance": .string($0.importance.rawValue)]
                })
            },
            ClaudeTool(
                name: "list_widget_types",
                description: "List the widget kinds that can be placed on the dashboard, with each kind's config JSON schema and default config."
            ) { _ in
                .array(host.widgetTypes.map {
                    ["kind": .string($0.kind), "name": .string($0.displayName), "summary": .string($0.summary),
                     "config_schema": $0.configSchema, "default_config": $0.defaultConfig]
                })
            },
            ClaudeTool(
                name: "list_pages",
                description: "List the dashboard's pages (sidebar items) with ids, names, icons, widget counts and which one is on screen."
            ) { _ in .array(store.pages().map(store.describe)) },
            ClaudeTool(
                name: "create_page",
                description: "Create a new page in the sidebar. Then add widgets to it with add_widget and page_id.",
                properties: ["name": JSONSchema.string("Page name."), "icon": JSONSchema.string("SF Symbol name.", enum: DashboardStore.pageIcons)],
                required: ["name"]
            ) { input in
                let request = try input.toolInput(PageInput.self)
                return store.describe(store.createPage(name: request.name, systemImage: request.icon ?? "square.grid.2x2"))
            },
            ClaudeTool(
                name: "update_page",
                description: "Rename a page or change its icon.",
                properties: ["id": JSONSchema.string("Page id."), "name": JSONSchema.string("New name."),
                             "icon": JSONSchema.string("SF Symbol name.", enum: DashboardStore.pageIcons)],
                required: ["id"]
            ) { input in
                let request = try input.toolInput(PageUpdateInput.self)
                try store.updatePage(try uuid(request.id), name: request.name, systemImage: request.icon)
                return store.describe(try store.page(try uuid(request.id)))
            },
            ClaudeTool(
                name: "delete_page",
                description: "Delete a page and the widgets on it.",
                properties: ["id": JSONSchema.string("Page id.")], required: ["id"], requiresApproval: true
            ) { input in
                try store.deletePage(try uuid(try input.toolInput(PageIDInput.self).id))
                return "deleted"
            },
            ClaudeTool(
                name: "list_widgets",
                description: "List widgets in reading order with ids, page_id, kinds, titles, grid position and size (x, y, w, h on a 12-column grid) and configs. Call this before answering questions about the dashboard.",
                properties: ["page_id": JSONSchema.string("Only this page (default: every page).")]
            ) { input in
                let page = try input.toolInput(ListInput.self).page_id.map(uuid)
                // Hidden widgets (extension missing or turned off) aren't on screen; leave them out.
                return .array(store.widgets(on: page).filter { host.isWidgetAvailable($0.kind) }.map(store.describe))
            },
            ClaudeTool(
                name: "read_widget",
                description: "Read one widget's live data (for example the issues on a Jira board widget or the PRs in a pull request widget), what the widget type is, what it shows right now beyond its config (ui_state: search, selection, visible range) and the actions you can run on it with widget_act.",
                properties: ["id": JSONSchema.string("Widget id from list_widgets.")], required: ["id"]
            ) { input in try await store.snapshot(uuid(input.toolInput(WidgetID.self).id)) },
            ClaudeTool(
                name: "widget_act",
                description: "Do something with a widget on screen, as the user would: search, filter, select a row, jump to a date… The actions a widget offers are listed by read_widget. They only change what the widget shows. The widget must be on the current page (view_show opens its page).",
                properties: ["id": JSONSchema.string("Widget id."), "action": JSONSchema.string("Action name from read_widget."),
                             "input": ["type": "object", "description": "The action's input, per its input_schema."]],
                required: ["id", "action"]
            ) { input in
                let request = try input.toolInput(ActInput.self)
                let id = try uuid(request.id)
                let record = try store.widget(id)
                guard let type = host.widgetType(record.kind) else { throw ToolError("Unknown widget kind \"\(record.kind)\".") }
                guard type.actions.contains(where: { $0.name == request.action }) else {
                    throw ToolError("\(type.displayName) has no action \"\(request.action)\". Actions: \(type.actions.map(\.name).joined(separator: ", ").isEmpty ? "none" : type.actions.map(\.name).joined(separator: ", ")).")
                }
                let live = host.live(id)
                live.attention = .now
                let result = try await live.perform(request.action, input: request.input ?? .object([:]))
                // Let the view settle so the state it reports reflects the action.
                try? await Task.sleep(for: .milliseconds(150))
                return ["result": result, "ui_state": live.state]
            },
            ClaudeTool(
                name: "add_widget",
                description: "Add a widget to the end of the dashboard. `config` is merged over the kind's default config.",
                properties: [
                    "kind": JSONSchema.string("Widget kind from list_widget_types."),
                    "title": JSONSchema.string("Card title. Defaults to the kind's name."),
                    "size": JSONSchema.string("Card size.", enum: sizes),
                    "config": JSONSchema.object("Config fields to set, following the kind's config_schema."),
                    "page_id": JSONSchema.string("Page to add it to (default: the page on screen)."),
                ], required: ["kind"]
            ) { input in
                let request = try input.toolInput(AddInput.self)
                return store.describe(try store.add(kind: request.kind, title: request.title, size: request.size, config: request.config,
                                                    page: try request.page_id.map(uuid)))
            },
            ClaudeTool(
                name: "update_widget",
                description: "Change a widget's title, size or config. `config` is merged over the current config, so pass only the fields to change.",
                properties: [
                    "id": JSONSchema.string("Widget id from list_widgets."),
                    "title": JSONSchema.string("New card title."),
                    "size": JSONSchema.string("New card size.", enum: sizes),
                    "config": JSONSchema.object("Config fields to change."),
                ], required: ["id"]
            ) { input in
                let request = try input.toolInput(UpdateInput.self)
                let id = try uuid(request.id)
                try store.update(id, title: request.title, size: request.size, config: request.config)
                return store.describe(try store.widget(id))
            },
            ClaudeTool(
                name: "place_widget",
                description: "Move and/or resize a widget on the 12-column grid (x 0-11, y rows from the top, w columns, h rows of 40 pt). Overlapped widgets move down and gaps close upward.",
                properties: [
                    "id": JSONSchema.string("Widget id."), "x": JSONSchema.integer("Column, 0-11."), "y": JSONSchema.integer("Row, 0 is the top."),
                    "w": JSONSchema.integer("Width in columns (2-12)."), "h": JSONSchema.integer("Height in rows (3+)."),
                    "page_id": JSONSchema.string("Move it to this page first."),
                ],
                required: ["id"]
            ) { input in
                let request = try input.toolInput(PlaceInput.self)
                let id = try uuid(request.id)
                try store.place(id, x: request.x, y: request.y, w: request.w, h: request.h, page: try request.page_id.map(uuid))
                return store.describe(try store.widget(id))
            },
            ClaudeTool(
                name: "remove_widget",
                description: "Remove a widget from the dashboard.",
                properties: ["id": JSONSchema.string("Widget id.")], required: ["id"], requiresApproval: true
            ) { input in
                try store.remove(uuid(input.toolInput(WidgetID.self).id))
                return "removed"
            },
        ]
    }
}
