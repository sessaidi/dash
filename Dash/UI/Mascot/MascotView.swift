import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// Dashii floating over the dashboard (or the desktop), with its speech bubble. Drag to move; click to ask.
struct MascotOverlay: View {
    /// On the desktop (in its own floating panel) rather than inside the Dash window.
    var desktop = false
    @Environment(ExtensionHost.self) private var host
    @Environment(ChatSession.self) private var chat
    @State private var controller = MascotController()
    /// The pointer relative to Dashii's root, in rig points.
    @State private var cursor: CGPoint?
    @State private var dragOffset = CGSize.zero
    @State private var question = ""
    @State private var awaitingAnswer = false
    @State private var mouseMonitor: Any?
    @State private var localMonitor: Any?
    @State private var petting = false
    @State private var dragStart: NSPoint?
    @AppStorage("mascot.offsetX") private var offsetX = 0.0
    @AppStorage("mascot.offsetY") private var offsetY = 0.0
    @FocusState private var askFocused: Bool

    private var persona: Persona { host.persona }

    var body: some View {
        if persona.mascotVisible, (persona.place == .desktop) == desktop {
            VStack(alignment: bubbleRight ? .leading : .trailing, spacing: 6) {
                if !bubbleBelow, let bubble = controller.bubble {
                    bubbleView(bubble)
                        .transition(.scale(scale: 0.85, anchor: bubbleAnchor).combined(with: .opacity))
                }
                DashiiView(direction: direction, scale: scale)
                    .overlay(alignment: .topTrailing) {
                        if controller.unread > 0 {
                            Text("\(controller.unread)")
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.red, in: .capsule)
                                .offset(x: -6, y: 6)
                                .accessibilityLabel("\(controller.unread) waiting")
                        }
                    }
                    .contentShape(DashiiBody(scale: scale))
                    .onHover { inside in
                        petting = inside
                        if inside { controller.touch() }
                    }
                    .onTapGesture(count: 2) {
                        // Double-click: the full conversation in Dash.
                        chat.isPanelVisible = true
                        controller.dismiss()
                        DesktopMascot.shared.bringDashForward()
                    }
                    .onTapGesture {
                        if controller.bubble?.kind == .ask { controller.dismiss() } else { controller.openAsk(); focusAsk() }
                    }
                    .gesture(
                        // On the desktop the drag moves the panel itself, in screen coordinates.
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if desktop {
                                    let mouse = NSEvent.mouseLocation
                                    if dragStart == nil { dragStart = mouse; DesktopMascot.shared.beginDrag() }
                                    if let start = dragStart { DesktopMascot.shared.drag(by: CGSize(width: mouse.x - start.x, height: mouse.y - start.y)) }
                                } else {
                                    dragOffset = value.translation
                                }
                            }
                            .onEnded { value in
                                if desktop {
                                    DesktopMascot.shared.endDrag()
                                    dragStart = nil
                                } else {
                                    offsetX += value.translation.width
                                    offsetY += value.translation.height
                                }
                                dragOffset = .zero
                                controller.touch()
                            })
                    .contextMenu {
                        Button("Ask \(persona.name)…") { controller.openAsk(); focusAsk() }
                        Menu("Play") {
                            ForEach(DashiiClip.allCases.filter { $0 != .enter && $0 != .exit }, id: \.self) { clip in
                                Button(clip.rawValue.capitalized) { play(clip) }
                            }
                        }
                        if controller.unread > 0 { Button("Clear \(controller.unread) Waiting Tips") { controller.clearQueue() } }
                        if desktop { Button("Open Dash") { DesktopMascot.shared.bringDashForward() } }
                        Button(desktop ? "Move Into the Dash Window" : "Move to the Desktop") {
                            persona.place = desktop ? .window : .desktop
                        }
                        if desktop {
                            Toggle("Climb Onto Windows", isOn: Binding(get: { persona.climbsWindows }, set: { persona.climbsWindows = $0 }))
                            Toggle("Wander Around", isOn: Binding(get: { persona.roams }, set: { persona.roams = $0 }))
                                .disabled(persona.climbsWindows)
                        }
                        Picker("Tips", selection: Binding(get: { persona.chattiness }, set: { persona.chattiness = $0 })) {
                            ForEach(Persona.Chattiness.allCases) { Text($0.title).tag($0) }
                        }
                        Divider()
                        Button("Hide \(persona.name)") { persona.mascotVisible = false }
                    }
                    .help("\(persona.name) — click to ask, double-click for the full chat, drag to move, right-click for options")
                    .accessibilityElement()
                    .accessibilityLabel("\(persona.name), your assistant")
                    .accessibilityAddTraits(.isButton)
                if bubbleBelow, let bubble = controller.bubble {
                    bubbleView(bubble)
                        .transition(.scale(scale: 0.85, anchor: bubbleAnchor).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: controller.bubble)
            .padding(desktop ? 8 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: Alignment(horizontal: bubbleRight ? .leading : .trailing, vertical: bubbleBelow ? .top : .bottom))
            .offset(x: desktop ? 0 : offsetX + dragOffset.width, y: desktop ? 0 : offsetY + dragOffset.height)
            .onChange(of: controller.bubble) { _, bubble in
                guard desktop else { return }
                DesktopMascot.shared.busy = bubble != nil
                if bubble != nil { DesktopMascot.shared.layOutBubble() }
                DesktopMascot.shared.updateHitTesting()
            }
            .onAppear {
                controller.greetIfNeeded(name: persona.name)
                startTrackingMouse()
            }
            .onReceive(NotificationCenter.default.publisher(for: .summonMascot)) { note in
                controller.openAsk()
                focusAsk()
                // From a notification's "Ask Dashii": ask straight away.
                if let prompt = note.object as? String { ask(prompt) }
            }
            .onDisappear {
                if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
                if let localMonitor { NSEvent.removeMonitor(localMonitor) }
                mouseMonitor = nil
                localMonitor = nil
            }
            .onChange(of: host.activity.events.count) {
                controller.observe(host.activity.events, chattiness: persona.chattiness)
            }
            .onChange(of: chat.isRunning) { _, running in
                guard !running, awaitingAnswer else { return }
                awaitingAnswer = false
                let answer = chat.transcript.last { if case .text = $0.kind { return true }; return false }
                let windowChatVisible = chat.isPanelVisible && NSApp.isActive
                if case .text(let text)? = answer?.kind, desktop || !windowChatVisible { controller.showAnswer(text) } else { controller.dismiss() }
            }
        }
    }

    /// On the desktop the bubble opens below and/or to the right of Dashii when there's no room
    /// above or to the left on screen (see DesktopMascot.layOutBubble).
    private var bubbleBelow: Bool { desktop && stage.bubbleBelow }
    private var bubbleRight: Bool { desktop && stage.bubbleRight }
    private var bubbleAnchor: UnitPoint {
        UnitPoint(x: bubbleRight ? 0 : 1, y: bubbleBelow ? 0 : 1)
    }

    private func bubbleView(_ bubble: MascotController.Bubble) -> some View {
        BubbleView(bubble: bubble, name: persona.name, question: $question, askFocused: $askFocused,
                   working: chat.isRunning && awaitingAnswer,
                   onAsk: ask, onAskAbout: { ask("Tell me what I should know about this: \($0)") },
                   onReply: { controller.openAsk(); focusAsk() },
                   onOpenChat: {
                       chat.isPanelVisible = true
                       if desktop { DesktopMascot.shared.bringDashForward() }
                       controller.dismiss()
                   },
                   onDismiss: { controller.dismiss() },
                   tailOnTop: bubbleBelow, tailFromLeading: bubbleRight,
                   tailOffset: bubbleRight ? DashiiView.root(scale: scale).x : DashiiView.size(scale: scale).width - DashiiView.root(scale: scale).x)
    }

    private var scale: CGFloat { desktop ? DesktopMascot.scale : 0.5 }
    private var stage: DashiiStage { DesktopMascot.shared.stage }

    private var mood: MascotController.Mood { controller.mood(isClaudeWorking: chat.isRunning) }

    /// Climbing beats a clip picked from the menu, which beats the mood.
    private var direction: DashiiDirection {
        let climb = desktop ? stage.climbClip : nil
        let mood = mood
        return DashiiDirection(clip: climb ?? stage.manualClip ?? MascotController.clip(for: mood), cursor: cursor,
                               contacts: desktop ? stage.contacts : [], attention: controller.attention && climb == nil,
                               sleepy: mood == .sleepy, talking: mood == .talking, petted: petting && !chat.isRunning,
                               fidgets: controller.bubble == nil, motion: desktop ? stage.motion : nil)
    }

    private func play(_ clip: DashiiClip) {
        stage.manualClip = clip
        let seconds = DashiiAssets.shared.clips?.clips[clip.rawValue].map { $0.loop ? $0.duration * 2 : $0.duration + 0.4 } ?? 3
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if stage.manualClip == clip { stage.manualClip = nil }
        }
    }

    private func focusAsk() {
        if desktop { DesktopMascot.shared.focus() } else { NSApp.activate() }
        askFocused = true
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chat.isRunning else { return }
        awaitingAnswer = true
        question = ""
        controller.touch()
        chat.send(trimmed)
    }

    /// Dashii's gaze follows the pointer anywhere on screen (desktop) or in the window.
    private func startTrackingMouse() {
        guard mouseMonitor == nil else { return }
        if desktop {
            // Anywhere on screen: a global monitor (other apps) plus a local one (Dash's own windows).
            let update: () -> Void = {
                guard let center = DesktopMascot.shared.center else { return }
                let mouse = NSEvent.mouseLocation
                DesktopMascot.shared.updateHitTesting(mouse: mouse)
                cursor = CGPoint(x: (mouse.x - center.x) / scale, y: -(mouse.y - center.y) / scale)
            }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
                MainActor.assumeIsolated { update() }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
                update()
                return event
            }
            return
        }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            if let window = event.window, !(window is MascotPanel), let content = window.contentView {
                // Dashii sits in the bottom-right corner (18 pt padding) plus its saved offset; AppKit y is up.
                let size = DashiiView.size(scale: scale), root = DashiiView.root(scale: scale)
                let center = CGPoint(x: content.bounds.maxX - 18 - size.width + root.x + offsetX,
                                     y: 18 + size.height - root.y - offsetY)
                let point = event.locationInWindow
                cursor = CGPoint(x: (point.x - center.x) / scale, y: -(point.y - center.y) / scale)
            }
            return event
        }
    }
}

/// The part of the Dashii canvas that takes clicks: its body, not the empty corners for props.
private struct DashiiBody: Shape {
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        let root = DashiiView.root(scale: scale)
        return Path(roundedRect: CGRect(x: root.x - 82 * scale, y: root.y - 142 * scale, width: 164 * scale, height: 210 * scale),
                    cornerRadius: 30 * scale)
    }
}

private struct BubbleView: View {
    let bubble: MascotController.Bubble
    let name: String
    @Binding var question: String
    var askFocused: FocusState<Bool>.Binding
    let working: Bool
    let onAsk: (String) -> Void
    let onAskAbout: (String) -> Void
    let onReply: () -> Void
    let onOpenChat: () -> Void
    let onDismiss: () -> Void
    var tailOnTop = false
    var tailFromLeading = false
    /// Distance of the tail tip from the bubble's trailing (or leading) edge: Dashii's head.
    var tailOffset: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(name).font(.subheadline.bold()).foregroundStyle(.tint)
                if bubble.importance == .critical { Badge("needs you", tone: .danger) }
                Spacer()
                Button("Close", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
            }
            switch bubble.kind {
            case .ask:
                if working {
                    HStack { ProgressView().controlSize(.small); Text("On it…").foregroundStyle(.secondary) }
                } else {
                    TextField("Ask \(name) anything", text: $question, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused(askFocused)
                        .onSubmit { onAsk(question) }
                    // One-click questions.
                    FlowChips(items: ["What needs me?", "What's new?", "Plan my day"]) { onAsk($0) }
                    HStack {
                        Spacer()
                        Button("Ask") { onAsk(question) }.keyboardShortcut(.defaultAction)
                            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            case .answer:
                ScrollView {
                    MarkdownText(bubble.text, lineSpacing: 4)
                        .font(.body)
                        .padding(.trailing, 6)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Chat", action: onOpenChat)
                    Spacer()
                    Button("Thanks", action: onDismiss)
                    Button("Reply", action: onReply).keyboardShortcut(.defaultAction)
                }
            case .tip(_, let link):
                Text(bubble.text).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let link, let url = URL(string: link) {
                        Button("Open") { NSWorkspace.shared.open(url); onDismiss() }
                    }
                    Spacer()
                    Button("Not now", action: onDismiss)
                    Button("Ask \(name)") { onAskAbout(bubble.text) }.keyboardShortcut(.defaultAction)
                }
            case .greeting:
                Text(bubble.text).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Got it", action: onDismiss).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, tailOnTop ? 22 : 12)
        .padding(.bottom, tailOnTop ? 12 : 22)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .overlay(shape.stroke(.separator))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private var shape: BubbleShape { BubbleShape(tailOnTop: tailOnTop, tailFromLeading: tailFromLeading, tailOffset: tailOffset) }
}

/// A rounded rectangle with a tail pointing at the mascot's head, below or above the bubble.
private struct BubbleShape: Shape {
    var tailOnTop = false
    var tailFromLeading = false
    var tailOffset: CGFloat = 88

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + (tailOnTop ? 10 : 0), width: rect.width, height: rect.height - 10)
        var path = Path(roundedRect: body, cornerRadius: 14)
        let tip = tailFromLeading ? body.minX + tailOffset : body.maxX - tailOffset
        let base = tailOnTop ? body.minY : body.maxY
        path.move(to: CGPoint(x: tip - 12, y: base))
        path.addLine(to: CGPoint(x: tip, y: tailOnTop ? rect.minY : rect.maxY))
        path.addLine(to: CGPoint(x: tip + 8, y: base))
        path.closeSubpath()
        return path
    }
}

/// Small tappable suggestion chips.
private struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(item) { action(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
