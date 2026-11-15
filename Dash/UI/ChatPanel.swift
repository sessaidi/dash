import DashKit
import DashKitUI
import SwiftUI

struct ChatPanel: View {
    @State private var showingHistory = false
    /// Folds the panel into its narrow rail.
    var onFold: (() -> Void)?
    @Environment(ChatSession.self) private var chat
    @Environment(AppSettings.self) private var settings
    @Environment(ExtensionHost.self) private var host
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private let suggestions = [
        "What's on my plate today?",
        "Which open PRs have high-risk reviews?",
        "Summarise the last meeting and list action items",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.transcript.isEmpty && chat.live.isEmpty { emptyState }
                        ForEach(chat.transcript + chat.live) { ChatEntryView(entry: $0) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: chat.live) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.transcript.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if !settings.isClaudeConfigured { missingKeyBanner }
            Divider()
            commandSuggestions
            composer
        }
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                DashiiAvatar(thinking: chat.isRunning)
                    .frame(width: 30, height: 26)
                Text(host.persona.name).font(.headline)
            }
            Text("\(settings.model) · Claude Code").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("History", systemImage: "clock.arrow.circlepath") { showingHistory.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Past conversations")
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    ChatHistoryList(chat: chat) { showingHistory = false }
                }
            Button("New Chat", systemImage: "square.and.pencil") { chat.reset() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Start a new conversation")
            if let onFold {
                Button("Fold Panel", systemImage: "sidebar.trailing", action: onFold)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Fold the panel (⌃⌘K)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hi, I'm \(host.persona.name). Ask about your tickets, PRs, agents or meetings, or have me rearrange the dashboard.")
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) { chat.send(suggestion) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var missingKeyBanner: some View {
        HStack {
            Image(systemName: "terminal").foregroundStyle(.orange)
            Text("Install Claude Code (or set its path) to chat.").font(.callout)
            Spacer()
            SettingsLink { Text("Settings…") }
        }
        .padding(10)
        .background(.orange.opacity(0.1))
    }

    /// While typing "/…": the matching commands; click one to fill it in.
    @ViewBuilder
    private var commandSuggestions: some View {
        let typed = draft.trimmingCharacters(in: .whitespaces)
        if typed.hasPrefix("/"), !typed.contains(" ") {
            let prefix = String(typed.dropFirst()).lowercased()
            let matches = AutomationStore.shared.commands.filter { prefix.isEmpty || $0.name.hasPrefix(prefix) }.prefix(6)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(matches)) { command in
                        Button {
                            draft = "/\(command.name) "
                            composerFocused = true
                        } label: {
                            HStack {
                                Text("/\(command.name)").font(.callout.monospaced())
                                Text(command.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(host.persona.name)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(submit)
                // A request started elsewhere (Filter with Dashii…): put it here to finish.
                .onChange(of: chat.pendingDraft, initial: true) { _, text in
                    guard let text else { return }
                    draft = text
                    chat.pendingDraft = nil
                    composerFocused = true
                }
            if chat.isRunning {
                Button("Stop", systemImage: "stop.circle.fill") { chat.stop() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: submit)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        .thinkingGlow(chat.isRunning, in: RoundedRectangle(cornerRadius: 12))
        .padding(10)
    }

    private func submit() {
        guard !chat.isRunning else { return }
        chat.send(draft)
        draft = ""
    }
}

struct ChatEntryView: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
            }
        case .text(let text):
            MarkdownText(text)
        case .thinking(let text):
            DisclosureGroup {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
        case .tool(let name, let input, let result, let isError):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    CodeText(input)
                    if let result { CodeText(result).foregroundStyle(isError ? .red : .primary) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: result == nil ? "hammer" : isError ? "xmark.octagon" : "checkmark.circle")
                        .foregroundStyle(result == nil ? Color.secondary : isError ? .red : .green)
                    Text(name).font(.caption.monospaced())
                    if result == nil { ProgressView().controlSize(.mini) }
                }
            }
        case .notice(let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.callout)
                .foregroundStyle(isError ? .red : .secondary)
        case .choices(let choices):
            ChoicesView(choices: choices)
        case .layouts(let proposal):
            LayoutProposalView(proposal: proposal)
        }
    }
}

/// A question Dashii asked, with answers to click (or type).
private struct ChoicesView: View {
    let choices: ChatChoices
    @Environment(ChatSession.self) private var chat
    @State private var picked: Set<String> = []
    @State private var other = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(choices.question).font(.callout.weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(choices.options, id: \.self) { option in
                    let selected = picked.contains(option) || choices.answer?.contains(option) == true
                    Button {
                        if choices.multiple { picked.formSymmetricDifference([option]) } else { chat.answer(choices.id, with: [option]) }
                    } label: {
                        Text(option)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                    .disabled(answered || chat.isRunning)
                }
            }
            if !answered {
                HStack(spacing: 8) {
                    if choices.allowOther {
                        TextField("Something else…", text: $other)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendOther)
                    }
                    if choices.multiple {
                        Button("Send") { chat.answer(choices.id, with: choices.options.filter(picked.contains) + otherAnswer) }
                            .buttonStyle(.borderedProminent)
                            .disabled(picked.isEmpty && otherAnswer.isEmpty)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 12))
        .opacity(answered ? 0.7 : 1)
    }

    private var answered: Bool { choices.answer != nil }
    private var otherAnswer: [String] { other.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [other.trimmingCharacters(in: .whitespaces)] }
    private func sendOther() { if !otherAnswer.isEmpty { chat.answer(choices.id, with: choices.options.filter(picked.contains) + otherAnswer) } }
}

/// Layouts Dashii proposed, each drawn as a miniature of the 12-column grid.
private struct LayoutProposalView: View {
    let proposal: LayoutProposal
    @Environment(ChatSession.self) private var chat
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Layouts for “\(proposal.pageName)”", systemImage: proposal.icon).font(.callout.weight(.semibold))
            ForEach(proposal.options) { option in
                let chosen = proposal.chosen == option.id
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(option.title).font(.callout.weight(.semibold))
                        Spacer()
                        if chosen {
                            Label("Built", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        } else if proposal.chosen == nil {
                            Button("Use This Layout") { chat.choose(option.id, in: proposal.id) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(chat.isRunning)
                        }
                    }
                    if !option.rationale.isEmpty {
                        Text(option.rationale).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    LayoutMiniature(widgets: option.widgets) { kind in host.widgetType(kind)?.systemImage ?? "square" }
                }
                .padding(10)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen ? AnyShapeStyle(.green.opacity(0.7)) : AnyShapeStyle(.separator.opacity(0.6))))
                .opacity(proposal.chosen != nil && !chosen ? 0.5 : 1)
            }
            if let pageID = proposal.pageID {
                Button("Open the Page", systemImage: "arrow.right.circle") {
                    host.selectedPageID = pageID
                    host.mainView = "page"
                }
                .buttonStyle(.borderless).font(.callout)
            }
        }
    }
}

/// The 12-column grid in small: each widget a tile with its icon and title.
struct LayoutMiniature: View {
    let widgets: [ProposedWidget]
    let icon: (String) -> String

    private var rows: Int { max(widgets.map { $0.y + $0.h }.max() ?? 1, 1) }

    var body: some View {
        GeometryReader { geometry in
            let column = geometry.size.width / 12
            let row = geometry.size.height / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                ForEach(Array(widgets.enumerated()), id: \.offset) { index, widget in
                    VStack(spacing: 2) {
                        Image(systemName: icon(widget.kind)).font(.caption)
                        if CGFloat(widget.h) * row > 34 {
                            Text(widget.title).font(.system(size: 9, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                    .foregroundStyle(Self.color(index))
                    .padding(3)
                    .frame(width: max(CGFloat(widget.w) * column - 3, 4), height: max(CGFloat(widget.h) * row - 3, 4))
                    .background(Self.color(index).opacity(0.16), in: .rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.color(index).opacity(0.5)))
                    .offset(x: CGFloat(widget.x) * column, y: CGFloat(widget.y) * row)
                    .help("\(widget.title) · \(widget.w)×\(widget.h)")
                }
            }
        }
        .aspectRatio(12 / (CGFloat(rows) * 0.55), contentMode: .fit)
        .frame(maxHeight: 220)
    }

    static func color(_ index: Int) -> Color { [Color.blue, .orange, .purple, .teal, .pink, .green, .indigo, .red][index % 8] }
}

/// Wraps its children onto new lines, like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Markdown with block structure: paragraphs, headings, bullet and numbered lists, quotes and
/// code fences each get their own spacing, and inline styles (bold, code, links) inside them.
struct MarkdownText: View {
    let text: String
    var lineSpacing: CGFloat = 3
    init(_ text: String, lineSpacing: CGFloat = 3) {
        self.text = text
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).lineSpacing(lineSpacing).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title3.bold() : .headline).padding(.top, 2)
        case .item(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                inline(text).lineSpacing(lineSpacing).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            inline(text).foregroundStyle(.secondary).lineSpacing(lineSpacing)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .code(let text):
            CodeText(text)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// A list item: "•" or "3.", nesting depth, text.
    case item(marker: String, indent: Int, text: String)
    case quote(String)
    case code(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if trimmed.isEmpty {
                flush()
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"), trimmed[hashes] == " " {
                flush()
                blocks.append(.heading(level: trimmed.distance(from: trimmed.startIndex, to: hashes), text: String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                flush()
                blocks.append(.item(marker: "•", indent: indent, text: String(trimmed.dropFirst(2))))
            } else if let dot = trimmed.firstIndex(of: "."), dot > trimmed.startIndex, trimmed[..<dot].allSatisfy(\.isNumber),
                      trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.item(marker: String(trimmed[...dot]), indent: indent, text: String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

struct CodeText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.count > 4000 ? String(text.prefix(4000)) + "…" : text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

/// The chat panel at the window's right edge, like the left sidebar: drag its edge to resize,
/// fold it to a rail with Dashii's face (click to unfold). ⌘K shows or hides it, ⌃⌘K folds it.
/// Everything is laid out at fixed widths inside a container whose width animates, so showing,
/// hiding and folding slide instead of popping.
struct ChatSidePanel: View {
    var visible = true
    @Environment(ChatSession.self) private var chat
    @Environment(ExtensionHost.self) private var host
    @AppStorage("chat.folded", store: DashDefaults.shared) private var folded = false
    @AppStorage("chat.width", store: DashDefaults.shared) private var width = 400.0
    @State private var dragStart: Double?

    static let widthRange = 320.0...720.0
    static let railWidth = 52.0

    private var shownWidth: Double { visible ? (folded ? Self.railWidth : width) : 0 }

    var body: some View {
        HStack(spacing: 0) {
            Divider()
                .overlay {
                    if !folded {
                        // A wider invisible grip over the divider for resizing.
                        Color.clear
                            .frame(width: 8)
                            .contentShape(.rect)
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    if dragStart == nil { dragStart = width }
                                    width = min(max((dragStart ?? width) - value.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                                }
                                .onEnded { _ in dragStart = nil })
                    }
                }
            ZStack(alignment: .topLeading) {
                ChatPanel(onFold: { toggle() })
                    .frame(width: width)
                    .opacity(folded ? 0 : 1)
                    .allowsHitTesting(!folded)
                rail
                    .frame(width: Self.railWidth)
                    .opacity(folded ? 1 : 0)
                    .allowsHitTesting(folded)
            }
            .frame(width: max(shownWidth - 1, 0), alignment: .leading)
            .clipped()
        }
        .frame(width: shownWidth, alignment: .leading)
        .clipped()
        .background(.background)
        .background {
            Button("Fold Chat Panel") { toggle() }
                .keyboardShortcut("k", modifiers: [.command, .control])
                .hidden()
        }
    }

    private var rail: some View {
        VStack(spacing: 14) {
            Button { toggle() } label: {
                DashiiAvatar(thinking: chat.isRunning)
                    .frame(width: 36, height: 30)
                    .overlay(alignment: .bottomTrailing) {
                        if chat.isRunning {
                            ProgressView().controlSize(.mini).offset(x: 6, y: 6)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Unfold \(host.persona.name) (⌃⌘K)")
            // The face unfolds; these do something else.
            Button("New Chat", systemImage: "square.and.pencil") {
                chat.reset()
                toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Start a new conversation")
            Button("Hide Panel", systemImage: "xmark") { chat.isPanelVisible = false }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide the panel (⌘K)")
            Spacer()
        }
        .padding(.top, 12)
        .frame(maxHeight: .infinity)
    }

    private func toggle() {
        withAnimation(.smooth(duration: 0.32)) { folded.toggle() }
    }
}

/// Past conversations: search, reopen (it continues where it stopped), delete.
private struct ChatHistoryList: View {
    let chat: ChatSession
    let onOpen: () -> Void
    @State private var search = ""
    @State private var conversations: [ChatConversation] = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search conversations", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            let shown = conversations.filter { conversation in
                search.isEmpty || conversation.title.localizedCaseInsensitiveContains(search)
                    || conversation.entries.contains { entry in
                        switch entry.kind {
                        case .user(let text), .text(let text): text.localizedCaseInsensitiveContains(search)
                        default: false
                        }
                    }
            }
            if shown.isEmpty {
                Text(conversations.isEmpty ? "No past conversations yet." : "Nothing matches.")
                    .foregroundStyle(.secondary).padding(20)
            } else {
                List(shown) { conversation in
                    Button {
                        chat.open(conversation)
                        onOpen()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.title).lineLimit(2)
                                Text(conversation.updated.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if conversation.id == chat.conversationID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            chat.delete(conversation)
                            conversations = chat.conversations()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 340, height: 420)
        .onAppear {
            chat.saveConversation()
            conversations = chat.conversations()
        }
    }
}
