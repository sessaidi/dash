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
                        SuggestionCard(suggestion: item, onOpen: { open(item) }, onDismiss: { home?.dismiss(item) })
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
        guard !chat.isRunning else { return }
        chat.isPanelVisible = true
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
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HomeCard(icon: suggestion.icon, title: header, action: onOpen) {
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
        .help(suggestion.prompt.map { "Ask: \($0)" } ?? suggestion.title)
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
