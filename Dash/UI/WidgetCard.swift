import DashKit
import DashKitUI
import SwiftUI

struct WidgetCard: View {
    let widget: WidgetRecord
    @Environment(ExtensionHost.self) private var host
    @Environment(\.isGridEditing) private var editing
    @State private var showSettings = false
    @State private var wiggle = false
    /// The widget's menu shows when the pointer is over it (no card to anchor it otherwise).
    @State private var hovering = false
    @State private var dashiiLooking = false

    var body: some View {
        let type = host.widgetType(widget.kind)
        // A filter linked to another widget's selection runs with the selected values, and not at
        // all while nothing is selected there.
        let linked = DashQL.resolveSelections(widget.query, host: host)
        let context = WidgetContext(widgetID: widget.id, host: host, aiTasks: type?.aiTasks ?? [],
                                    queryText: linked.waiting.isEmpty ? linked.text : "")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // The header is the drag handle; the content keeps its own gestures.
                HStack(spacing: 8) {
                    Image(systemName: type?.systemImage ?? "questionmark.square")
                        .foregroundStyle(.secondary)
                    Text(widget.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(.rect)
                // Press and hold a header to unlock the layout, like a home screen.
                .onLongPressGesture(minimumDuration: 0.45) {
                    guard !editing else { return }
                    withAnimation(.snappy(duration: 0.2)) { host.layoutEditing = true }
                }
                if !editing, let type, !widget.query.isEmpty {
                    FilterChip(widget: widget, fields: type.queryFields)
                }
                if !editing { menu.opacity(hovering ? 1 : 0) }
            }
            Group {
                if let owner = host.owner(ofWidget: widget.kind), !host.isEnabled(owner) {
                    StateView(.empty(title: "\(owner.name) is turned off", systemImage: "power", message: "Turn it on in Settings › Features."),
                              action: ("Open Settings", { host.openManager(owner.id) }))
                } else if let owner = host.owner(ofWidget: widget.kind), case let missing = host.unmetRequirements(of: owner), !missing.isEmpty {
                    StateView(.needsConnection(names: missing.map { host.integration($0)?.name ?? $0 }),
                              action: ("Connect…", { host.openManager(missing[0]) }))
                } else if let type {
                    type.content(host.dashboard.configBinding(for: widget), context)
                } else {
                    // Its plugin isn't installed (or was removed): the widget keeps its place and config.
                    StateView(.empty(title: "Not installed", systemImage: "puzzlepiece.extension",
                                     message: "The extension that provides “\(widget.kind)” isn't installed. Install it from the Marketplace."),
                              action: ("Open Marketplace", { host.openManager("marketplace") }))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Widgets read their size and size family (narrow, medium, wide, large) from here.
            .measuresWidgetLayout()
            // Dashii reads and drives the widget through this.
            .environment(\.widgetLive, host.live(widget.id))
            // While editing, the whole card is a drag handle and its content doesn't take clicks.
            .allowsHitTesting(!editing)
        }
        // Controls the widget puts in its header (`widgetHeader`): on the title row, left of the menu.
        .overlayPreferenceValue(WidgetHeaderKey.self, alignment: .topTrailing) { items in
            if !editing, !items.isEmpty {
                HStack(spacing: 8) { ForEach(items) { $0.view } }
                    .frame(height: 22)
                    .padding(.trailing, 30)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Outside edit mode widgets sit on the page itself (no card); the card appears while
        // editing so each one can be seen, moved and resized.
        .background(editing ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 14))
        .animation(.smooth(duration: 0.25), value: editing)
        .onHover { hovering = $0 }
        .modifier(DragWhenEditing(editing: editing))
        // A soft glow while Dashii reads or drives the widget.
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tint.opacity(dashiiLooking ? 0.7 : 0), lineWidth: 2)
                .shadow(color: .accentColor.opacity(dashiiLooking ? 0.45 : 0), radius: 8)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.35), value: dashiiLooking)
        }
        .onChange(of: host.live(widget.id).attention) { _, date in
            guard date != nil else { return }
            dashiiLooking = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                dashiiLooking = false
            }
        }
        .overlay(alignment: .topLeading) {
            if editing {
                Button {
                    withAnimation(.snappy) { try? host.dashboard.remove(widget.id) }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color(nsColor: .systemGray), in: .circle)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .offset(x: -7, y: -7)
                .help("Remove \(widget.title)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        // The home-screen wiggle: a tiny alternating tilt, out of phase from card to card.
        .rotationEffect(.degrees(editing ? (wiggle ? 0.35 : -0.35) : 0))
        .animation(editing ? .easeInOut(duration: 0.13 + Double(abs(widget.id.hashValue) % 5) * 0.01).repeatForever(autoreverses: true) : .default,
                   value: wiggle)
        .onChange(of: editing, initial: true) { _, on in wiggle = on }
        .contextMenu { menuItems }
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            WidgetSettingsForm(widget: widget, type: type, context: context)
        }
    }

    private var menu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Shared by the ⋯ button and the right-click menu.
    @ViewBuilder
    private var menuItems: some View {
            Button("Settings…", systemImage: "slider.horizontal.3") { showSettings = true }
            Button("Ask Dashii", systemImage: "bubble.left") {
                host.askDashii("Read widget \"\(widget.title)\" (id \(widget.id.uuidString)) and tell me what stands out.")
            }
            if host.widgetType(widget.kind)?.queryFields.isEmpty == false {
                Button("Filter with Dashii…", systemImage: "line.3.horizontal.decrease.circle") {
                    host.draftForClaude("Filter “\(widget.title)” to show ")
                }
            }
            Picker("Size Preset", selection: Binding(get: { widget.size }, set: { try? host.dashboard.update(widget.id, size: $0) })) {
                ForEach(WidgetSize.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Button(host.layoutEditing ? "Done Editing Layout" : "Edit Layout", systemImage: "square.and.pencil") {
                withAnimation(.snappy(duration: 0.2)) { host.layoutEditing.toggle() }
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) { try? host.dashboard.remove(widget.id) }
    }
}

private struct WidgetSettingsForm: View {
    let widget: WidgetRecord
    let type: WidgetType?
    let context: WidgetContext
    @Environment(ExtensionHost.self) private var host

    @State private var tab = "general"

    var body: some View {
        let tasks = type?.aiTasks ?? []
        VStack(spacing: 0) {
            if !tasks.isEmpty {
                Picker("Section", selection: $tab) {
                    Text("General").tag("general")
                    Label("AI", systemImage: "sparkles").tag("ai")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 14)
            }
            if tab == "ai", !tasks.isEmpty {
                AISettingsView(scope: .widget(widget.id), tasks: tasks)
                    .frame(width: 460, height: 520)
            } else {
                Form {
                    TextField("Title", text: Binding(get: { widget.title }, set: { widget.title = $0 }))
                    if let type, type.hasSettings {
                        type.settings(host.dashboard.configBinding(for: widget), context)
                    }
                }
                .formStyle(.grouped)
                .frame(width: tasks.isEmpty ? 380 : 460)
                .frame(minHeight: 160)
            }
        }
    }
}

/// Makes the whole card the grid's drag handle while editing.
private struct DragWhenEditing: ViewModifier {
    let editing: Bool

    func body(content: Content) -> some View {
        if editing { content.gridDragHandle() } else { content }
    }
}

/// What Dashii filtered the widget to, in plain words; clear it or ask Dashii to change it.
/// The DashQL behind it is only in the tooltip: the user talks to Dashii, not in queries.
private struct FilterChip: View {
    let widget: WidgetRecord
    let fields: [QueryDataset.Field]
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        let linked = DashQL.resolveSelections(widget.query, host: host)
        let summary = !linked.waiting.isEmpty
            ? "Select something in \(linked.waiting.joined(separator: ", "))"
            : (try? WidgetQuery(linked.text, fields: fields))??.summary ?? widget.query
        Menu {
            Button("Change Filter…", systemImage: "bubble.left") {
                host.draftForClaude("Change the filter on “\(widget.title)” (now: \(summary)) to show ")
            }
            Button("Show Everything", systemImage: "xmark.circle") { try? host.dashboard.setQuery(widget.id, "") }
        } label: {
            Label(summary, systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.tint.opacity(0.14), in: .capsule)
        .help("Filtered by \(host.persona.name): \(summary)\n\(widget.query)")
    }
}
