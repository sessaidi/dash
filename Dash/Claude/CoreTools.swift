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
    private struct QueryInput: Decodable { let id: String; let query: String }
    private struct ActInput: Decodable { let id: String; let action: String; let input: JSONValue? }

    private static func uuid(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw ToolError("\"\(text)\" is not an id. Call list_widgets or list_pages.") }
        return id
    }

    static func tools(host: ExtensionHost) -> [DashiiTool] {
        let store = host.dashboard!
        let sizes = WidgetSize.allCases.map(\.rawValue)
        return [
            DashiiTool(
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
            DashiiTool(
                name: "list_widget_types",
                description: "List the widget kinds that can be placed on the dashboard, with each kind's config JSON schema and default config."
            ) { _ in
                .array(host.widgetTypes.map {
                    ["kind": .string($0.kind), "name": .string($0.displayName), "summary": .string($0.summary),
                     "config_schema": $0.configSchema, "default_config": $0.defaultConfig]
                })
            },
            DashiiTool(
                name: "list_pages",
                description: "List the dashboard's pages (sidebar items) with ids, names, icons, widget counts and which one is on screen."
            ) { _ in .array(store.pages().map(store.describe)) },
            DashiiTool(
                name: "create_page",
                description: "Create a new page in the sidebar. Then add widgets to it with add_widget and page_id.",
                properties: ["name": JSONSchema.string("Page name."), "icon": JSONSchema.string("SF Symbol name.", enum: DashboardStore.pageIcons)],
                required: ["name"]
            ) { input in
                let request = try input.toolInput(PageInput.self)
                return store.describe(store.createPage(name: request.name, systemImage: request.icon ?? "square.grid.2x2"))
            },
            DashiiTool(
                name: "layout_context",
                description: "Everything needed to suggest a layout: the widget types you can place (summary, default size, size limits, config schema, actions), which integrations are connected, what's installed, plugins in the Marketplace not installed yet, the current pages and their widgets, and which sources were busiest this week.",
            ) { _ in layoutContext(host: host) },
            DashiiTool(
                name: "suggest_layout",
                description: "Start a suggested layout: creates a draft page the user can Keep, Change or Discard. Then add and place widgets on it (add_widget with page_id, place_widget), configured for the user (repos, namespaces, filters), most important top-left. Ask the user about their needs first unless you already know them.",
                properties: ["name": JSONSchema.string("Page name, e.g. On-call."), "icon": JSONSchema.string("SF Symbol name.", enum: DashboardStore.pageIcons),
                             "rationale": JSONSchema.string("One or two sentences on why this layout, shown on the draft.")],
                required: ["name", "rationale"]
            ) { input in
                let request = try input.toolInput(DraftInput.self)
                let page = store.createDraftPage(name: request.name, systemImage: request.icon ?? "sparkles", rationale: request.rationale)
                host.selectedPageID = page.id
                host.mainView = "page"
                return store.describe(page)
            },
            DashiiTool(
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
            DashiiTool(
                name: "delete_page",
                description: "Delete a page and the widgets on it.",
                properties: ["id": JSONSchema.string("Page id.")], required: ["id"], requiresApproval: true
            ) { input in
                try store.deletePage(try uuid(try input.toolInput(PageIDInput.self).id))
                return "deleted"
            },
            DashiiTool(
                name: "list_widgets",
                description: "List widgets in reading order with ids, page_id, kinds, titles, grid position and size (x, y, w, h on a 12-column grid) and configs. Call this before answering questions about the dashboard.",
                properties: ["page_id": JSONSchema.string("Only this page (default: every page).")]
            ) { input in
                let page = try input.toolInput(ListInput.self).page_id.map(uuid)
                // Hidden widgets (extension missing or turned off) aren't on screen; leave them out.
                return .array(store.widgets(on: page).filter { host.isWidgetAvailable($0.kind) }.map(store.describe))
            },
            DashiiTool(
                name: "read_widget",
                description: "Read one widget's live data (for example the issues on a Jira board widget or the PRs in a pull request widget), what the widget type is, what it shows right now beyond its config (ui_state: search, selection, visible range) and the actions you can run on it with widget_act.",
                properties: ["id": JSONSchema.string("Widget id from list_widgets.")], required: ["id"]
            ) { input in try await store.snapshot(uuid(input.toolInput(WidgetID.self).id)) },
            DashiiTool(
                name: "widget_query",
                description: "Set a widget's DashQL filter (saved with it): what it shows, filtered, sorted and cut, e.g. `ns:papi-eu status:failing | sort -restarts | take 20`. It may follow another widget's selection: `tickets ~ $selected(\"Jira board\").key`. Empty clears it. read_widget lists the widget's query_fields; the user sees and can edit the query.",
                properties: ["id": JSONSchema.string("Widget id."), "query": JSONSchema.string("DashQL without a source (filter | sort | take), or empty.")],
                required: ["id", "query"]
            ) { input in
                let request = try input.toolInput(QueryInput.self)
                let id = try uuid(request.id)
                try store.setQuery(id, request.query)
                host.live(id).attention = .now
                return store.describe(try store.widget(id))
            },
            DashiiTool(
                name: "widget_act",
                description: "Do something with a widget on screen, as the user would: search, select a row, jump to a date… The actions a widget offers are listed by read_widget. They're temporary (not saved): for a lasting filter use widget_query, for settings update_widget. The widget must be on the current page (view_show opens its page).",
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
            DashiiTool(
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
            DashiiTool(
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
            DashiiTool(
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
            DashiiTool(
                name: "remove_widget",
                description: "Remove a widget from the dashboard.",
                properties: ["id": JSONSchema.string("Widget id.")], required: ["id"], requiresApproval: true
            ) { input in
                try store.remove(uuid(input.toolInput(WidgetID.self).id))
                return "removed"
            },
        ]
    }

    /// What `layout_context` returns.
    static func layoutContext(host: ExtensionHost) -> JSONValue {
        let store = host.dashboard!
        let types: [JSONValue] = host.widgetTypes.filter { host.isWidgetAvailable($0.kind) }.map { type in
            ["kind": .string(type.kind), "name": .string(type.displayName), "summary": .string(type.summary),
             "default_size": .string(type.defaultSize.rawValue),
             "size_limits": ["min_w": .number(Double(type.sizeLimits.minW)), "min_h": .number(Double(type.sizeLimits.minH)),
                             "max_w": .number(Double(type.sizeLimits.maxW)), "max_h": .number(Double(type.sizeLimits.maxH))],
             "config_schema": type.configSchema, "actions": .array(type.actions.map { .string($0.name) })]
        }
        let integrations: [JSONValue] = host.extensions.filter { $0.layer == .integration }.map { item in
            ["id": .string(item.id), "name": .string(item.name), "enabled": .bool(host.isEnabled(item)),
             "connected": .bool(host.integration(item.id)?.connection != nil)]
        }
        let installed = Set(host.extensions.map(\.id))
        let marketplace: [JSONValue] = (host.ext(MarketplaceFeature.self)?.catalogs.values.flatMap(\.index.extensions) ?? [])
            .filter { !installed.contains($0.id) && $0.builtIn != true }
            .map { ["id": .string($0.id), "name": .string($0.name), "description": .string($0.description ?? "")] }
        let pages: [JSONValue] = store.pages().map { page in
            store.describe(page).merging(["widget_kinds": .array(store.widgets(on: page.id).map { .string($0.kind) })])
        }
        var busiest: [String: Int] = [:]
        for event in host.activity.events(since: .now.addingTimeInterval(-7 * 86400)) { busiest[event.source, default: 0] += 1 }
        return ["widget_types": .array(types), "integrations": .array(integrations), "marketplace_not_installed": .array(marketplace),
                "pages": .array(pages),
                "busiest_sources_this_week": .object(busiest.mapValues { .number(Double($0)) }),
                "grid": "12 columns, rows of 40 pt; x, y, w, h in cells. Put what the user checks first top-left and wide."]
    }
}
