import ClaudeCodeKit
import DashKit
import DashKitUI
import SwiftUI

/// The top of the Home page: a greeting, recent notes and Claude usage, suggested tasks from
/// plugins and activity, and Claude's daily brief. The ask bar floats at the bottom of the page
/// (`HomeAskBar`). Configured in Settings › Plugins › Features › Home.
struct HomeHeader: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(ChatSession.self) private var chat

    private var home: HomeExtension? { host.ext(HomeExtension.self) }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            greeting
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                if let notes = host.ext(NotesExtension.self) {
                    RecentNotesCard(notes: notes) { host.mainView = "notes" }
                }
                UsageCard()
                if home?.showsSuggestions != false {
                    ForEach(Array(host.homeSuggestions.prefix(4))) { item in
                        SuggestionCard(suggestion: item, onOpen: { open(item) }, onAsk: ask, onDismiss: { home?.dismiss(item) })
                    }
                }
            }
            if let home, home.showsBrief {
                BriefCard(home: home, context: briefContext, onAsk: ask)
            }
        }
        .frame(maxWidth: 880, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .task {
            // Once a day, if asked to: write the brief the first time Home is shown.
            if let home, home.showsBrief, home.autoBrief, !home.briefIsFromToday {
                await home.writeBrief(context: briefContext)
            }
        }
    }

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = home?.userName ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            Text(name.isEmpty ? "\(part) 👋" : "\(part), \(name) 👋")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(.tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
                .padding(.leading, -14)
            Text("How can \(host.persona.name) help today?")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    /// What the brief is written from: plugins' suggestions and the recent activity.
    private var briefContext: String {
        let suggestions = host.homeSuggestions.filter { !$0.id.hasPrefix("setup.") }.prefix(12)
            .map { "- \($0.title)\($0.detail.map { ": \($0)" } ?? "")" }.joined(separator: "\n")
        let activity = ActivityLog.digest(host.activity.events, limit: 30) ?? ""
        return [suggestions.isEmpty ? nil : "Waiting:\n\(suggestions)", activity.isEmpty ? nil : "Recent activity:\n\(activity)"]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    private func open(_ suggestion: Suggestion) {
        if let prompt = suggestion.prompt {
            ask(prompt)
        } else if let link = suggestion.link {
            NSWorkspace.shared.open(link)
        } else if suggestion.source == "notes" {
            host.mainView = "notes"
        } else {
            host.openManager(suggestion.source)
        }
    }

    private func ask(_ text: String) {
        // Busy: at least show the conversation, so the click isn't lost.
        chat.isPanelVisible = true
        guard !chat.isRunning else { return }
        chat.send(text)
    }
}

/// The Home page's floating ask bar.
struct HomeAskBar: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(ChatSession.self) private var chat
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(LinearGradient(colors: [.purple, .accentColor], startPoint: .topLeading, endPoint: .bottomTrailing))
            Divider().frame(height: 22)
            TextField("Ask \(host.persona.name) anything about your work…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
        .thinkingGlow(chat.isRunning, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .frame(maxWidth: 880)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty && !chat.isRunning }

    private func send() {
        guard canSend else { return }
        chat.isPanelVisible = true
        chat.send(question.trimmingCharacters(in: .whitespacesAndNewlines))
        question = ""
    }
}

/// A Home card: a small grey header with an icon, then content.
private struct HomeCard<Content: View>: View {
    let icon: String
    let title: String
    var action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(hovering && action != nil ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.separator.opacity(0.5))))
        .contentShape(.rect(cornerRadius: 18))
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
    }
}

private struct RecentNotesCard: View {
    let notes: NotesExtension
    let onOpen: () -> Void

    var body: some View {
        HomeCard(icon: "doc.text", title: "Recent notes", action: onOpen) {
            let recent = Array(notes.store.notes.prefix(3))
            if recent.isEmpty {
                Text("No notes yet. Start one in Notes.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recent) { note in
                        HStack(spacing: 8) {
                            Image(systemName: "note.text").foregroundStyle(.tint)
                            Text(note.title).lineLimit(1)
                            Spacer()
                            Text(note.modified.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .onAppear { notes.store.reload() }
    }
}

private struct UsageCard: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(AppSettings.self) private var settings
    private var usage: ClaudeUsage { .shared }

    var body: some View {
        HomeCard(icon: "gauge.with.dots.needle.33percent", title: "Claude usage", action: {
            host.settingsTab = "claude"
            host.claudeSection = "usage"
            host.openManagerWindow?()
        }) {
            if let meter = usage.limits?.meters.first {
                PlanMeterRow(meter: meter)
            } else {
                let today = usage.totals(days: 1)
                Text("\(today.calls) requests today · \(today.costUSD.formatted(.currency(code: "USD")))")
                    .font(.title3.weight(.semibold))
                Text(usage.isReadingLimits ? "Reading your plan's limits…" : "Your plan's limits appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if usage.limits == nil { await usage.refreshLimits(executable: settings.claudeExecutable) } }
    }
}

private struct SuggestionCard: View {
    let suggestion: Suggestion
    let onOpen: () -> Void
    let onAsk: (String) -> Void
    let onDismiss: () -> Void
    @State private var hovering = false
    @State private var showingDetails = false

    var body: some View {
        // Suggestions open their details first (what it's about, then ask or open); setup cards act directly.
        HomeCard(icon: suggestion.icon, title: header, action: suggestion.id.hasPrefix("setup.") ? onOpen : { showingDetails = true }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(2)
                if let detail = suggestion.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.bold()) }
                    .buttonStyle(.borderless)
                    .padding(12)
                    .help("Not today")
            }
        }
        .onHover { hovering = $0 }
        .help(suggestion.id.hasPrefix("setup.") ? suggestion.title : "Show details")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            SuggestionDetails(suggestion: suggestion, onAsk: { prompt in
                showingDetails = false
                onAsk(prompt)
            }, onOpen: {
                showingDetails = false
                onOpen()
            })
        }
    }

    private var header: String {
        switch suggestion.priority {
        case .urgent: "Needs you now"
        case .high: "Suggested · important"
        default: suggestion.id.hasPrefix("setup.") ? "Get started" : "Suggested task"
        }
    }
}

private struct BriefCard: View {
    let home: HomeExtension
    let context: String
    let onAsk: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(.secondary)
                Text("Today's brief").font(.title3.weight(.semibold))
                if let count = home.brief?.items.count, count > 0 {
                    Text("\(count)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let brief = home.brief {
                    Text("\(brief.date.formatted(date: .omitted, time: .shortened)) · \(brief.model)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Button { Task { await home.writeBrief(context: context) } } label: {
                    HStack(spacing: 6) {
                        if home.isWritingBrief { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.stars") }
                        Text(home.brief == nil ? "Plan My Day" : "Replan")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [.purple, .accentColor], startPoint: .leading, endPoint: .trailing), lineWidth: 1.5))
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(home.isWritingBrief)
            }
            if let brief = home.brief, !brief.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(brief.items.enumerated()), id: \.offset) { index, item in
                        BriefRow(item: item, color: [Color.orange, .red, .blue, .purple, .teal][index % 5]) {
                            if let prompt = item.prompt { onAsk(prompt) }
                        }
                    }
                }
                if !home.briefIsFromToday {
                    Text("From \(brief.date.formatted(date: .abbreviated, time: .omitted)). Replan for today.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = home.briefError {
                Text(error).font(.callout).foregroundStyle(.red)
            } else {
                Text("Let Claude propose today's work from your role, your focus and what's waiting on your dashboard.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct BriefRow: View {
    let item: HomeExtension.BriefItem
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(item.title).font(.callout.weight(.medium))
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                        .lineLimit(1)
                }
                Spacer()
                if item.prompt != nil, hovering {
                    Label("Ask", systemImage: "arrow.up.right").font(.caption).foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.prompt.map { "Ask: \($0)" } ?? "")
    }
}

/// A suggestion's items (tickets, PRs…), each opening its page or asked about, and asking Dashii
/// about all of them.
private struct SuggestionDetails: View {
    let suggestion: Suggestion
    let onAsk: (String) -> Void
    let onOpen: () -> Void
    @Environment(ExtensionHost.self) private var host

    /// The items, or, from older plugins that send one line, its " · " parts.
    private var rows: [Suggestion.Item] {
        if !suggestion.items.isEmpty { return suggestion.items }
        return (suggestion.detail ?? "").components(separatedBy: " · ").filter { !$0.isEmpty }.map { Suggestion.Item(title: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: suggestion.icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title).font(.headline)
                    Text(kicker).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !rows.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                            ItemRow(item: item, tint: tint) { key in
                                onAsk("Tell me about \(key): where it stands, what's blocking it and the next step.")
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if suggestion.link != nil || suggestion.prompt == nil {
                    Button("Open", systemImage: "arrow.up.forward.square", action: onOpen)
                }
                if let prompt = suggestion.prompt {
                    Button("Ask \(host.persona.name)", systemImage: "sparkles") { onAsk(prompt) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 480)
    }

    private var tint: Color {
        switch suggestion.priority {
        case .urgent: .red
        case .high: .orange
        default: .accentColor
        }
    }

    private var kicker: String {
        let count = rows.count
        let what = suggestion.priority == .urgent ? "Needs you now" : suggestion.priority == .high ? "Important" : "Suggested"
        return count > 1 ? "\(what) · \(count) items" : what
    }

    private struct ItemRow: View {
        let item: Suggestion.Item
        let tint: Color
        let ask: (String) -> Void
        @State private var hovering = false

        /// "LAF-6173 Backend: …" splits into the key and the rest.
        private var parts: (key: String?, title: String) {
            if let match = item.title.firstMatch(of: /^([A-Z][A-Z0-9]+-\d+|[\w.-]+\/[\w.-]+#\d+)\s+(.*)$/) {
                return (String(match.output.1), String(match.output.2))
            }
            return (nil, item.title)
        }

        var body: some View {
            let parts = parts
            HStack(alignment: .center, spacing: 10) {
                if let key = parts.key {
                    Text(key)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tint.opacity(0.14), in: .capsule)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(parts.title).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    if let key = parts.key {
                        Button("Ask about \(key)", systemImage: "bubble.left") { ask(key) }
                    }
                    if let link = item.link {
                        Button("Open", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.open(link) }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.8)) : AnyShapeStyle(.quaternary.opacity(0.4)), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { if let link = item.link { NSWorkspace.shared.open(link) } }
        }
    }
}
