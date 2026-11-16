import DashKit
import DashKitUI
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(ChatSession.self) private var chat
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \DashboardPage.order) private var pages: [DashboardPage]
    @State private var editing: PageEditor.Target?
    /// Crashes since the user last saw one, shown once at launch.
    @State private var unseenCrashes: [CrashReport] = []
    /// Collapsed = an icon rail instead of a hidden sidebar.
    @AppStorage("sidebar.compact", store: DashDefaults.shared) private var compact = false
    @AppStorage("chat.folded", store: DashDefaults.shared) private var chatFolded = false
    @AppStorage("chat.width", store: DashDefaults.shared) private var chatWidth = 400.0
    @AppStorage("chat.expanded", store: DashDefaults.shared) private var chatExpanded = false

    /// Home's width with both panels open, but never narrower than a comfortable reading
    /// width when the panels leave room for it.
    private func dismissCrashes() {
        CrashReports.markSeen(unseenCrashes, defaults: DashDefaults.shared)
        unseenCrashes = []
    }

    private func homeWidth(window: Double, free: Double) -> Double {
        let withPanelsOpen = window - 221 - (chat.isPanelVisible ? ChatSidePanel.width(chatWidth, expanded: chatExpanded, window: window) : 0)
        return max(min(free, max(withPanelsOpen, 720)), 320)
    }

    var body: some View {
        @Bindable var chat = chat
        @Bindable var host = host
        // Home keeps the width it has with both panels open, centred in the space the panels
        // leave: folding either one slides it to the middle without reflowing it. Notes and
        // dashboards use whatever room there is.
        let isNotes = host.mainView == "notes"
        let isHome = host.mainView == "page" && (pages.first { $0.id == host.selectedPageID } ?? pages.first)?.showsHome == true
        let leading = (compact ? 64.0 : 220.0) + 1
        GeometryReader { geometry in
        let trailing = !chat.isPanelVisible ? 0
            : chatFolded ? ChatSidePanel.railWidth
            : ChatSidePanel.width(chatWidth, expanded: chatExpanded, window: geometry.size.width)
        ZStack(alignment: .trailing) {
            ZStack(alignment: .leading) {
            Group {
                if host.mainView == "notes", let notes = host.ext(NotesExtension.self) {
                    NotesView(notes: notes)
                        .navigationTitle("Notes")
                } else if host.mainView == "knowledge", let knowledge = host.ext(KnowledgeExtension.self) {
                    KnowledgeView(knowledge: knowledge)
                        .navigationTitle("Knowledge")
                } else if let page = pages.first(where: { $0.id == host.selectedPageID }) ?? pages.first {
                    VStack(spacing: 0) {
                        if page.isDraft { DraftLayoutBanner(page: page) }
                        DashboardGrid(pageID: page.id, editing: host.layoutEditing, showsHome: page.showsHome)
                    }
                    .id(page.id)
                    .navigationTitle(page.name)
                } else {
                    ProgressView()
                }
            }
            .frame(width: isHome ? homeWidth(window: geometry.size.width, free: geometry.size.width - leading - trailing) : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) { MascotOverlay() }
            .padding(.leading, leading)
            HStack(spacing: 0) {
                Sidebar(pages: pages, compact: compact, editing: $editing) {
                    withAnimation(.smooth(duration: 0.32)) { compact.toggle() }
                }
                    .frame(width: compact ? 64 : 220, alignment: .leading)
                    .clipped()
                Divider()
            }
            }
            .padding(.trailing, trailing)
            // Always present: its width animates to zero when hidden, so it slides in and out.
            ChatSidePanel(visible: chat.isPanelVisible, window: geometry.size.width)
        }
        }
        .animation(.smooth(duration: 0.32), value: chat.isPanelVisible)
        .animation(.smooth(duration: 0.32), value: chatFolded)
        .toolbar {
            toolbar
        }
        .sheet(item: $editing) { PageEditor(target: $0) }
        .onChange(of: host.selectedPageID) { host.layoutEditing = false }
        .onReceive(NotificationCenter.default.publisher(for: .dashNewPage)) { _ in editing = .new(section: nil) }
        .onReceive(NotificationCenter.default.publisher(for: .dashAddWidget)) { _ in host.openWidgetGallery() }
        .onReceive(NotificationCenter.default.publisher(for: .dashRenamePage)) { _ in
            if let page = pages.first(where: { $0.id == host.selectedPageID }) { editing = .edit(page) }
        }
        .sheet(isPresented: $host.widgetGalleryVisible) { WidgetGallery() }
        // Once after a crash: what macOS recorded (newest first).
        .sheet(isPresented: Binding(get: { !unseenCrashes.isEmpty }, set: { if !$0 { dismissCrashes() } })) {
            CrashNoticeSheet(crashes: unseenCrashes, ask: { host.askDashii($0) }, done: dismissCrashes)
        }
        .task {
            unseenCrashes = CrashReports.unseen(defaults: DashDefaults.shared)
            DashiiHealth.shared.refreshCrashes()
        }
        .permissionModal(host.permissionCenter)
        .onAppear {
            host.openManagerWindow = { openSettings() }
            if host.selectedPageID == nil { host.selectedPageID = pages.first?.id }
            DesktopMascot.shared.sync(host: host, chat: chat)
        }
        .onChange(of: host.persona.place) { DesktopMascot.shared.sync(host: host, chat: chat) }
        .onChange(of: host.persona.mascotVisible) { DesktopMascot.shared.sync(host: host, chat: chat) }
        .onChange(of: host.persona.roams) { DesktopMascot.shared.sync(host: host, chat: chat) }
        .onChange(of: host.persona.climbsWindows) { DesktopMascot.shared.sync(host: host, chat: chat) }
    }
}

/// Pages grouped into sections (Slack-style: rename by double-clicking a header, drag pages
/// between sections or onto another page to reorder), then app destinations. Plain SwiftUI so
/// folding animates: icons stay put (centred in the folded rail), the width and the selection
/// highlight ease, titles and headers fade. Every row shows its name as a tooltip.
private struct Sidebar: View {
    static let suggestLayoutPrompt = """
        Suggest a dashboard layout for me. Call layout_context, then ask me a few short questions about \
        my needs (what I check first, on-call, which repos and projects) unless you already know, then build \
        it with suggest_layout and place the widgets.
        """

    let pages: [DashboardPage]
    let compact: Bool
    @Binding var editing: PageEditor.Target?
    /// Shows or hides the page names (the button at the top of the column, ⌃⌘S).
    let toggle: () -> Void
    @Environment(ExtensionHost.self) private var host
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SidebarSection.order) private var sections: [SidebarSection]
    /// The section whose name is being edited (`.some(nil)` is the built-in one).
    @State private var renaming: UUID??
    @State private var draft = ""
    @State private var dropTarget: UUID??
    @State private var hoveredHeader: UUID??
    @State private var hoveredRow: String?
    @State private var dropBefore: UUID?
    @AppStorage(DashboardStore.defaultSectionKey + ".name", store: DashDefaults.shared) private var defaultName = "Pages"
    @FocusState private var nameFocused: Bool

    /// Side margin of the rows; with the row's own padding it puts every icon's centre 32 pt from
    /// the edge, the middle of the 64 pt folded rail.
    private static let margin: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            // The fold button sits in the column, its icon aligned with the others.
            Button(action: toggle) {
                row(compact ? "Show Names" : "Hide Names", icon: "sidebar.left", key: "sidebar.toggle")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(compact ? "Show page names (⌃⌘S)" : "Show icons only (⌃⌘S)")
            .padding(.horizontal, Self.margin)
            .padding(.top, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Dash's own places: Home, then Notes. Custom pages follow in their sections.
                    staticHeader("Dash")
                    if let home = homePage {
                        Button {
                            host.selectedPageID = home.id
                            host.mainView = "page"
                        } label: {
                            row("Home", icon: "house", key: "home", tinted: true, selected: host.mainView == "page" && host.selectedPageID == home.id)
                        }
                        .buttonStyle(.plain)
                    }
                    if host.ext(NotesExtension.self) != nil {
                        Button { host.mainView = "notes" } label: {
                            row("Notes", icon: "note.text", key: "notes", tinted: true, selected: host.mainView == "notes")
                        }
                        .buttonStyle(.plain)
                    }
                    if let knowledge = host.ext(KnowledgeExtension.self), host.isEnabled(knowledge) {
                        Button { host.mainView = "knowledge" } label: {
                            row("Knowledge", icon: knowledge.systemImage, key: "knowledge", tinted: true, selected: host.mainView == "knowledge")
                        }
                        .buttonStyle(.plain)
                    }
                    section(id: nil, name: defaultName)
                    ForEach(sections) { custom in
                        section(id: custom.id, name: custom.name)
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            .contentShape(.rect)
            .contextMenu {
                Button("New Page…", systemImage: "plus") { editing = .new(section: nil) }
                Button("Suggest a Layout…", systemImage: "sparkles") { host.askDashii(Self.suggestLayoutPrompt) }
                Button("New Section", systemImage: "folder.badge.plus") { newSection() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .dashNewSection)) { _ in newSection() }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                // New pages and sections come from the right-click menus (sidebar, section, page background).
                if host.settings.debugMode {
                    Button { openWindow(id: "debug") } label: { row("Debug", icon: "ladybug", key: "debug") }
                        .buttonStyle(.plain)
                }
                SettingsLink { row("Settings", icon: "gearshape", key: "settings") }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
            }
            .padding(.horizontal, Self.margin)
            .padding(.vertical, 8)
        }
        .background(.background.secondary)
    }

    /// The page with the Home header: it lives in the Dash section, not among custom pages.
    private var homePage: DashboardPage? { pages.first { $0.showsHome } }

    /// A section title that can't be renamed or dropped onto (the Dash section).
    private func staticHeader(_ name: String) -> some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 12)
            .padding(.top, 2)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(compact ? 0 : 1)
    }

    private func pages(in id: UUID?) -> [DashboardPage] {
        // Pages pointing at a section that no longer exists show in the built-in one; the Home
        // page sits in the Dash section.
        let known = Set(sections.map(\.id))
        let homeID = homePage?.id
        return pages.filter { $0.id != homeID }.filter { page in
            id == nil ? page.sectionID.map { !known.contains($0) } ?? true : page.sectionID == id
        }
    }

    @ViewBuilder
    private func section(id: UUID?, name: String) -> some View {
        let members = pages(in: id)
        header(id: id, name: name, showsRule: !members.isEmpty)
        ForEach(members) { page in pageRow(page, section: id) }
        if members.isEmpty {
            Text("Drag pages here")
                .font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(minWidth: 0, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .opacity(compact ? 0 : 1)
        }
    }

    @ViewBuilder
    private func header(id: UUID?, name: String, showsRule: Bool) -> some View {
        HStack(spacing: 4) {
            if renaming == .some(id), !compact {
                TextField("Section name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(name)
                    .onTapGesture(count: 2) { startRename(id, name) }
            }
            Spacer(minLength: 0)
            Menu {
                sectionMenu(id: id, name: name)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Section options")
            // Only while the pointer is over the header, like Slack.
            .opacity(hoveredHeader == .some(id) ? 1 : 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.top, 12)
        .padding(.bottom, 4)
        // Folded: the name fades (its height stays, so rows don't move) and a short rule marks
        // sections after the first.
        .opacity(compact ? 0 : 1)
        .overlay {
            if showsRule {
                Capsule().fill(.separator).frame(width: 22, height: 1.5)
                    .padding(.top, 8)
                    .opacity(compact ? 1 : 0)
            }
        }
        .background(dropTarget == .some(id) ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { inside in
            if inside { hoveredHeader = .some(id) } else if hoveredHeader == .some(id) { hoveredHeader = nil }
        }
        .contextMenu { sectionMenu(id: id, name: name) }
        .dropDestination(for: String.self) { items, _ in
            for item in items { if let page = UUID(uuidString: item) { host.dashboard.movePage(page, toSection: id) } }
            return !items.isEmpty
        } isTargeted: { targeted in
            if targeted { dropTarget = .some(id) } else if dropTarget == .some(id) { dropTarget = nil }
        }
    }

    @ViewBuilder
    private func sectionMenu(id: UUID?, name: String) -> some View {
        Button("Rename Section…", systemImage: "pencil") { startRename(id, name) }
        Button("New Page Here", systemImage: "plus") { editing = .new(section: id) }
        Button("New Section", systemImage: "folder.badge.plus") { newSection() }
        if let id {
            Divider()
            Button("Delete Section", systemImage: "trash", role: .destructive) { host.dashboard.deleteSection(id) }
                .help("Its pages move to \(defaultName)")
        }
    }

    private func pageRow(_ page: DashboardPage, section: UUID?) -> some View {
        Button {
            host.selectedPageID = page.id
            host.mainView = "page"
        } label: {
            row(page.name, icon: page.isDraft ? "sparkles" : page.systemImage, key: page.id.uuidString, tinted: true,
                selected: host.mainView == "page" && host.selectedPageID == page.id)
                .opacity(page.isDraft ? 0.75 : 1)
                .help(page.isDraft ? "Suggested by \(host.persona.name): open it to keep, change or discard" : page.name)
        }
        .buttonStyle(.plain)
        // A line above the row while another page is dragged onto it: dropping puts it here.
        .overlay(alignment: .top) {
            if dropBefore == page.id {
                Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -2)
            }
        }
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                if let moving = UUID(uuidString: item), moving != page.id {
                    host.dashboard.movePage(moving, toSection: section, before: page.id)
                }
            }
            return !items.isEmpty
        } isTargeted: { targeted in
            if targeted { dropBefore = page.id } else if dropBefore == page.id { dropBefore = nil }
        }
        .contextMenu {
            Button("Rename…") { editing = .edit(page) }
            Menu("Move to Section") {
                Button(defaultName) { host.dashboard.movePage(page.id, toSection: nil) }
                    .disabled(page.sectionID == nil)
                ForEach(sections) { custom in
                    Button(custom.name) { host.dashboard.movePage(page.id, toSection: custom.id) }
                        .disabled(page.sectionID == custom.id)
                }
                Divider()
                Button("New Section…") {
                    let section = host.dashboard.createSection(name: "New Section")
                    host.dashboard.movePage(page.id, toSection: section.id)
                    startRename(section.id, section.name)
                }
            }
            Divider()
            Button("Delete Page", role: .destructive) { try? host.dashboard.deletePage(page.id) }
                .disabled(pages.count < 2)
        }
    }

    private func newSection() {
        let section = host.dashboard.createSection(name: "New Section")
        if compact { return }
        startRename(section.id, section.name)
    }

    private func startRename(_ id: UUID?, _ name: String) {
        draft = name
        renaming = .some(id)
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard case .some(let id) = renaming else { return }
        renaming = nil
        host.dashboard.renameSection(id, to: draft)
        if id == nil { defaultName = host.dashboard.defaultSectionName }
    }

    /// One sidebar row. The icon sits at the same place in both widths; the title fades and is
    /// clipped by the row as the sidebar narrows, and the highlight shrinks with it.
    private func row(_ title: String, icon: String, key: String, tinted: Bool = false, selected: Bool = false) -> some View {
        HStack(spacing: compact ? 0 : 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 24, height: 22)
            // Gone in the icon rail, so the highlight is a square centred on the icon.
            if !compact {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, 6)
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? AnyShapeStyle(.quaternary) : hoveredRow == key ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .clipShape(.rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { inside in
            if inside { hoveredRow = key } else if hoveredRow == key { hoveredRow = nil }
        }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

extension RootView {
    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Widget", systemImage: "plus") { host.openWidgetGallery() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Add widgets to this page (⇧⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { host.layoutEditing.toggle() }
                } label: {
                    Label(host.layoutEditing ? "Done" : "Edit Layout",
                          systemImage: host.layoutEditing ? "checkmark.circle.fill" : "square.and.pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                .help(host.layoutEditing ? "Lock the layout (⌘E or Esc)" : "Move, resize, remove and add widgets (⌘E)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(host.persona.name, systemImage: "sparkles") { chat.isPanelVisible.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Show or hide \(host.persona.name) (⌘K)")
            }
            }
}

/// Create or rename a page: name and icon.
struct PageEditor: View {
    enum Target: Identifiable {
        /// A new page, in this section (nil: the built-in one).
        case new(section: UUID?)
        case edit(DashboardPage)
        var id: String { if case .edit(let page) = self { return page.id.uuidString }; return "new" }
    }

    let target: Target
    @Environment(ExtensionHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "square.grid.2x2"
    @State private var showsHome = false
    @State private var iconSearch = ""

    /// Icon groups filtered by the search text (matching SF Symbol names, e.g. "chart" or "lock").
    private var iconGroups: [(name: String, symbols: [String])] {
        let query = iconSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return DashboardStore.pageIconGroups }
        return DashboardStore.pageIconGroups.compactMap { group in
            let matches = group.symbols.filter { $0.contains(query) || group.name.lowercased().contains(query) }
            return matches.isEmpty ? nil : (group.name, matches)
        }
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("Deploys, On-call, Reviews…"))
            Toggle("Show the welcome, ask bar, suggestions and brief", isOn: $showsHome)
            LabeledContent("Icon") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search icons", text: $iconSearch, prompt: Text("Search icons"))
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(iconGroups, id: \.name) { group in
                                Text(group.name).font(.caption).foregroundStyle(.secondary)
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 10), spacing: 4) {
                                    ForEach(group.symbols, id: \.self) { symbol in
                                        Button { icon = symbol } label: {
                                            Image(systemName: symbol)
                                                .frame(width: 30, height: 30)
                                                .background(icon == symbol ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                                                .contentShape(.rect)
                                        }
                                        .buttonStyle(.plain)
                                        .help(symbol)
                                        .accessibilityLabel(symbol)
                                    }
                                }
                            }
                            if iconGroups.isEmpty {
                                Text("No icon matches “\(iconSearch)”.").foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 260)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            if case .edit(let page) = target { name = page.name; icon = page.systemImage; showsHome = page.showsHome }
        }
    }

    private var isNew: Bool { if case .new = target { return true }; return false }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch target {
        case .new(let section):
            let page = host.dashboard.createPage(name: trimmed, systemImage: icon, section: section)
            if showsHome { try? host.dashboard.updatePage(page.id, showsHome: true) }
            host.selectedPageID = page.id
        case .edit(let page): try? host.dashboard.updatePage(page.id, name: trimmed, systemImage: icon, showsHome: showsHome)
        }
        dismiss()
    }
}

/// The dashboard: a 12-column snap grid. In edit mode (⌘E) drag a card anywhere and resize it
/// from its corner; other cards move out of the way and gaps close. Otherwise the layout is locked.
struct DashboardGrid: View {
    let pageID: UUID
    /// Edit mode: drag cards anywhere, resize from the corner grip, remove; content is inert.
    var editing = false
    /// The Home header (greeting, ask bar, suggestions, brief) above the widgets.
    var showsHome = false
    @Environment(ExtensionHost.self) private var host
    @Query private var widgets: [WidgetRecord]
    @State private var appearance = Appearance.shared

    init(pageID: UUID, editing: Bool = false, showsHome: Bool = false) {
        self.pageID = pageID
        self.editing = editing
        self.showsHome = showsHome
        let page: UUID? = pageID
        _widgets = Query(filter: #Predicate<WidgetRecord> { $0.pageID == page }, sort: \.order)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !widgets.contains(where: { host.isWidgetAvailable($0.kind) }), showsHome {
                ScrollView {
                    HomeHeader().padding(.horizontal, 24)
                    Button("Add Widgets Below…", systemImage: "plus") { host.openWidgetGallery() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        // Room for the floating ask bar.
                        .padding(.bottom, 110)
                }
            } else if !widgets.contains(where: { host.isWidgetAvailable($0.kind) }) {
                ContentUnavailableView {
                    Label("Empty page", systemImage: "square.grid.2x2")
                } description: {
                    Text("Add widgets from the gallery, or ask \(host.persona.name) to build this page for you.")
                } actions: {
                    Button("Add Widgets…", systemImage: "plus") { host.openWidgetGallery() }
                        .buttonStyle(.borderedProminent)
                    Button("Ask \(host.persona.name)", systemImage: "sparkles") {
                        host.askDashii("Build this page for me: suggest and place widgets that fit its name.")
                    }
                }
            } else {
                // Widgets of uninstalled or turned-off extensions are hidden, not deleted.
                let shown = widgets.filter { $0.gridX >= 0 && host.isWidgetAvailable($0.kind) }
                let records = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0) })
                SnapGrid(
                    // Hidden widgets may have left overlaps behind when they come back; resolve them for display.
                    frames: host.dashboard.engine.compact(Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0.frame) })),
                    engine: host.dashboard.engine,
                    editing: editing,
                    limits: host.dashboard.limits(on: pageID),
                    header: showsHome && !editing ? AnyView(HomeHeader().padding(.horizontal, 8)) : nil,
                    onCommit: { host.dashboard.apply($0) }
                ) { id in
                    if let record = records[id] { WidgetCard(widget: record) }
                }
                // A click on the empty background ends editing, like tapping the home screen.
                .background { if editing { Color.clear.contentShape(.rect).onTapGesture { stopEditing() } } }
            }
            if editing {
                EditingBar(onAdd: { host.openWidgetGallery() }, onDone: stopEditing)
            } else if showsHome {
                HomeAskBar()
            }
        }
        .onExitCommand { if editing { stopEditing() } }
        .contextMenu { PageBackgroundMenu() }
        // The page colour from Settings › Appearance, behind the widgets.
        .background { if let page = appearance.page { page.ignoresSafeArea() } }
    }

    private func stopEditing() {
        withAnimation(.snappy(duration: 0.2)) { host.layoutEditing = false }
    }
}

/// Right-click on a page's background.
private struct PageBackgroundMenu: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Add Widget…", systemImage: "plus") { host.openWidgetGallery() }
        Button(host.layoutEditing ? "Done Editing Layout" : "Edit Layout", systemImage: "square.and.pencil") {
            withAnimation(.snappy(duration: 0.2)) { host.layoutEditing.toggle() }
        }
        Divider()
        Button("New Page…", systemImage: "doc.badge.plus") { NotificationCenter.default.post(name: .dashNewPage, object: nil) }
        Button("New Section", systemImage: "folder.badge.plus") { NotificationCenter.default.post(name: .dashNewSection, object: nil) }
        Button("Rename Page…", systemImage: "pencil") { NotificationCenter.default.post(name: .dashRenamePage, object: nil) }
        Divider()
        Button("Ask \(host.persona.name)…", systemImage: "sparkles") { NotificationCenter.default.post(name: .summonMascot, object: nil) }
        Button("Settings…", systemImage: "gearshape") { openSettings() }
    }
}

/// The floating bar while a page is in edit mode: add widgets, or finish.
private struct EditingBar: View {
    let onAdd: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Add Widget", systemImage: "plus", action: onAdd)
            Divider().frame(height: 18)
            Text("Drag to move · corner to resize").font(.callout).foregroundStyle(.secondary)
            Divider().frame(height: 18)
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// On a page Dashii suggested: why it's laid out this way, and Keep / Change / Discard.
struct DraftLayoutBanner: View {
    let page: DashboardPage
    @Environment(ExtensionHost.self) private var host
    @State private var confirmingDiscard = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggested by \(host.persona.name)").font(.callout.weight(.semibold))
                if !page.draftRationale.isEmpty {
                    Text(page.draftRationale).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 12)
            Button("Discard", role: .destructive) { confirmingDiscard = true }
            Button("Change…", systemImage: "bubble.left") {
                host.askDashii("Change the suggested layout on page “\(page.name)” (id \(page.id.uuidString)): ")
            }
            Button("Keep", systemImage: "checkmark") {
                withAnimation(.snappy) { try? host.dashboard.keepDraft(page.id) }
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(14)
        .background(.tint.opacity(0.06), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.tint.opacity(0.25)))
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .confirmationDialog("Discard the suggested “\(page.name)” page?", isPresented: $confirmingDiscard) {
            Button("Discard Page", role: .destructive) { withAnimation(.snappy) { try? host.dashboard.deletePage(page.id) } }
        }
    }
}
