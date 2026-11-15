import AppKit
import DashKit
import SwiftUI

/// A borderless panel that can take keyboard focus (for the quick-ask field) without
/// activating Dash.
final class MascotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// The panel's empty part may sit above the menu bar while Dashii perches near the top of the
    /// screen; AppKit would otherwise push the whole panel down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Dashii living on the desktop: a transparent floating panel over every app and Space. The panel
/// has a fixed size (resizing it made the mascot jump); its empty area is click-through, and only
/// Dashii (and the bubble, while one is open) takes the mouse.
///
/// With "climb onto the frontmost window" on, Dashii climbs onto the top edge of the frontmost
/// app's window (or inside its side edge when there's no room above), rides along when the window
/// moves, and jumps off and climbs onto the next one when another window comes to the front.
/// Dragged away, it stays where it was dropped until another window comes forward. With climbing
/// off, it stays where it was put, occasionally
/// hopping nearby.
@MainActor
final class DesktopMascot {
    static let shared = DesktopMascot()

    static let expandedSize = NSSize(width: 420, height: 600)
    /// Dashii's drawing scale on the desktop.
    static let scale: CGFloat = 0.55
    /// The mascot overlay's padding inside the panel.
    static let padding: CGFloat = 8

    let stage = DashiiStage()
    private var panel: MascotPanel?
    private var roamer: Task<Void, Never>?
    private var moveObserver: NSObjectProtocol?
    private var animating = false
    private var lastManualMove = Date.distantPast
    private weak var persona: Persona?
    /// A bubble is open: don't roam or switch windows.
    var busy = false

    /// Creates or removes the panel to match the persona's settings.
    func sync(host: ExtensionHost, chat: ChatSession) {
        let persona = host.persona
        self.persona = persona
        let wanted = persona.mascotVisible && persona.place == .desktop
        if wanted, panel == nil {
            create(host: host, chat: chat)
        } else if !wanted, let panel {
            panel.orderOut(nil)
            self.panel = nil
            roamer?.cancel()
            stopPerching()
            if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
            moveObserver = nil
        }
        guard wanted else { return }
        if persona.climbsWindows { startPerching() } else { stopPerching() }
        startRoaming(persona)
    }

    private func create(host: ExtensionHost, chat: ChatSession) {
        let panel = MascotPanel(contentRect: NSRect(origin: .zero, size: Self.expandedSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above full-screen apps too: status-bar level, on every Space, allowed beside full-screen windows.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Dragging is done by the mascot view so clicks and drags don't fight.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let content = MascotOverlay(desktop: true)
            .environment(host)
            .environment(host.settings)
            .environment(chat)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        panel.contentView = hosting
        // Restores the saved frame (if any) and saves every move from now on.
        let restored = panel.setFrameUsingName("DashDesktopMascot")
        panel.setFrameAutosaveName("DashDesktopMascot")
        if !restored {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.expandedSize.width - 24, y: screen.minY + 24))
        }
        // Older builds saved a compact frame: keep the mascot where it was (bottom-right corner), fixed size.
        if panel.frame.size != Self.expandedSize {
            let old = panel.frame
            panel.setFrame(NSRect(x: old.maxX - Self.expandedSize.width, y: old.minY, width: Self.expandedSize.width, height: Self.expandedSize.height), display: false)
        }
        clampToScreen(panel)
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.animating else { return }
                self.lastManualMove = Date()
            }
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    // MARK: Geometry

    /// The root bone (Dashii's torso centre) inside the panel, in AppKit coordinates (y up).
    /// Dashii sits in the panel's bottom-right corner, or top and/or left when the bubble opens
    /// below or to the right of it.
    static func rootInPanel(bubbleBelow: Bool = false, bubbleRight: Bool = false) -> CGPoint {
        let size = DashiiView.size(scale: scale), root = DashiiView.root(scale: scale)
        let x = bubbleRight ? padding + root.x : expandedSize.width - padding - size.width + root.x
        let y = bubbleBelow ? expandedSize.height - padding - root.y : padding + size.height - root.y
        return CGPoint(x: x, y: y)
    }

    private var rootInPanel: CGPoint { Self.rootInPanel(bubbleBelow: stage.bubbleBelow, bubbleRight: stage.bubbleRight) }

    /// The root on screen.
    var center: NSPoint? {
        guard let frame = panel?.frame else { return nil }
        return NSPoint(x: frame.minX + rootInPanel.x, y: frame.minY + rootInPanel.y)
    }

    /// Before a bubble opens: put it where it fits on screen (above or below, left or right of
    /// Dashii) and shift the panel so Dashii itself doesn't move.
    func layOutBubble() {
        guard let center, let screen = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame else { return }
        let s = Self.scale
        let bubble = CGSize(width: 380, height: 430)
        let headTop = center.y + 142 * s, feet = center.y - 68 * s
        let below = screen.maxY - headTop < bubble.height && feet - screen.minY > screen.maxY - headTop
        let headX = center.x
        let right = headX - screen.minX < bubble.width - DashiiView.size(scale: s).width + DashiiView.root(scale: s).x + 8
        guard below != stage.bubbleBelow || right != stage.bubbleRight else { return }
        stage.bubbleBelow = below
        stage.bubbleRight = right
        moveRoot(to: center)
    }

    /// Dashii's body (head to thruster) on screen: the part that takes clicks.
    var dotFrame: NSRect? {
        guard let center else { return nil }
        let s = Self.scale
        return NSRect(x: center.x - 82 * s, y: center.y - 68 * s, width: 164 * s, height: 210 * s)
    }

    /// Click-through except over Dashii, over the open bubble, or while dragging.
    func updateHitTesting(mouse: NSPoint = NSEvent.mouseLocation) {
        guard let panel, let dot = dotFrame else { return }
        let interactive = dot.contains(mouse) || (busy && panel.frame.contains(mouse)) || dragOrigin != nil
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    private func moveRoot(to point: CGPoint) {
        guard let panel else { return }
        // Half-point steps on Retina keep slow drifts from stair-stepping.
        let pixel = 1 / max(panel.backingScaleFactor, 1)
        let origin = NSPoint(x: ((point.x - rootInPanel.x) / pixel).rounded() * pixel,
                             y: ((point.y - rootInPanel.y) / pixel).rounded() * pixel)
        guard origin != panel.frame.origin else { return }
        animating = true
        panel.setFrameOrigin(origin)
        animating = false
    }

    // MARK: Dragging

    private var dragOrigin: NSPoint?

    func beginDrag() {
        dragOrigin = panel?.frame.origin
        // Carried off a window, Dashii stays where it's dropped until another window comes forward.
        switch phase {
        case .perched(let window), .entering(let window, _), .exiting(let window, _), .hopping(_, let window, _, _):
            phase = .parked(windowID: window.id)
        case .free, .parked:
            break
        }
        stage.climbClip = nil
        stage.contacts = []
        stage.motion.airborne = false
    }

    /// Moves the panel by a screen-space offset from where the drag began.
    func drag(by delta: CGSize) {
        guard let panel, let origin = dragOrigin else { return }
        animating = true
        panel.setFrameOrigin(NSPoint(x: origin.x + delta.width, y: origin.y + delta.height))
        animating = false
        lastManualMove = Date()
    }

    func endDrag() {
        dragOrigin = nil
        lastManualMove = Date()
        if let panel { clampToScreen(panel) }
        position = center
        velocity = .zero
        freeOrigin = panel?.frame.origin
        // Dropped close to the front window's perch: climb back on.
        if displayLink != nil, let front, let from = position, let spot = perch(on: front)?.point,
           hypot(spot.x - from.x, spot.y - from.y) < 140 {
            phase = .hopping(from: from, to: front, started: now, duration: 0.45)
        }
    }

    /// Keeps the panel on a screen so the bubble is readable.
    private func clampToScreen(_ panel: NSPanel) {
        let frame = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(dotFrame ?? frame) })?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = min(max(origin.x, screen.minX), screen.maxX - frame.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - frame.height)
        if origin != frame.origin {
            animating = true
            panel.setFrameOrigin(origin)
            animating = false
        }
    }

    /// Takes keyboard focus for the ask field without activating Dash.
    func focus() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func bringDashForward() {
        NSApp.activate()
        NSApp.windows.first { !($0 is MascotPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    // MARK: Climbing windows

    private enum Phase {
        case free
        /// Flying in from the screen edge and pulling up onto the first window.
        case entering(FrontWindow, started: Double)
        case perched(FrontWindow)
        /// Jumping in an arc from wherever Dashii is to another window.
        case hopping(from: CGPoint, to: FrontWindow, started: Double, duration: Double)
        /// Letting go and dropping off the screen: no window left to sit on.
        case exiting(FrontWindow, started: Double)
        /// Dragged off this window: stay put until a different window comes forward.
        case parked(windowID: Int)
    }

    private var phase = Phase.free
    private var loggedWindow: Int?
    /// Where Dashii was before it started climbing, to go back to when there's no window.
    private var freeOrigin: NSPoint?
    private var displayLink: CADisplayLink?
    private var frame = 0
    private var front: FrontWindow?
    /// A different window came forward: hop only once it has stayed in front briefly, so
    /// Cmd-Tabbing through apps doesn't send Dashii bouncing everywhere.
    private var candidate: (window: FrontWindow, since: Double)?
    /// Dashii's root on screen as last placed, and its velocity (screen points per second).
    private var position: CGPoint?
    private var velocity = CGVector.zero
    /// Switching Spaces (desktops, full-screen apps): the window list is in flux until then.
    private var settlingUntil = 0.0
    /// Pop onto the next window after a Space switch instead of hopping across the screen.
    private var popPending = false
    /// When the front window went missing, so a brief gap doesn't make Dashii let go.
    private var missingSince: Double?
    private var spaceObserver: NSObjectProtocol?

    private var now: Double { CACurrentMediaTime() }

    private func startPerching() {
        guard displayLink == nil, let view = panel?.contentView else { return }
        freeOrigin = panel?.frame.origin
        position = center
        // Stepped by the display, not a timer: one panel move per screen refresh, no judder.
        let link = view.displayLink(target: DisplayLinkTarget { [weak self] in self?.tick() }, selector: #selector(DisplayLinkTarget.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    /// Another desktop or a full-screen app came in: stay on top of it, wait for the window list
    /// to settle, then pop onto the new front window.
    private func spaceChanged() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        settlingUntil = now + 0.5
        popPending = true
        candidate = nil
        missingSince = nil
        panel.alphaValue = 0
    }

    /// Appears on `window` in place: a quick fade-in with a landing squash.
    private func pop(onto window: FrontWindow) {
        popPending = false
        guard let panel, let spot = perch(on: window)?.point else { panel?.alphaValue = 1; return }
        phase = .perched(window)
        stage.climbClip = nil
        stage.contacts = []
        stage.motion.airborne = false
        setRoot(spot, velocity: .zero)
        stage.motion.landedAt = Date().timeIntervalSince(DashiiClock.epoch)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    private func stopPerching() {
        displayLink?.invalidate()
        displayLink = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        panel?.alphaValue = 1
        stage.motion.velocity = .zero
        stage.motion.airborne = false
        if case .free = phase { return }
        phase = .free
        stage.climbClip = nil
        stage.contacts = []
        stage.edge = nil
    }

    private func tick() {
        // The window list is read about 20 times a second; the panel moves every frame.
        if frame % 3 == 0 { front = FrontWindow.current().flatMap { mostlyOnScreen($0) ? $0 : nil } }
        frame += 1
        step(now: now)
    }

    private func step(now: Double) {
        guard let panel, dragOrigin == nil else { return }
        if now < settlingUntil { return }
        if popPending {
            if let front {
                pop(onto: front)
            } else {
                // A Space with no window to sit on: show up where Dashii was.
                popPending = false
                panel.alphaValue = 1
            }
            return
        }
        // Brief gaps in the window list (transitions, a closing sheet) don't count as "no window".
        if front == nil {
            if missingSince == nil { missingSince = now }
        } else {
            missingSince = nil
        }
        let gone = (missingSince.map { now - $0 > 0.8 }) ?? false
        switch phase {
        case .free:
            if let front { phase = .entering(front, started: now) }
        case .parked(let id):
            if let next = settledFront(now: now), next.id != id, !busy, let from = position {
                phase = .hopping(from: from, to: next, started: now, duration: 0.9)
            }
        case .entering(let window, let started):
            let window = refreshed(window)
            let age = now - started
            if age > 3.24 {
                phase = .perched(window)
            } else {
                phase = .entering(window, started: started)
                place(on: window, clip: .enter, age: age)
            }
        case .perched(let window):
            let window = refreshed(window)
            if let next = settledFront(now: now), next.id != window.id, !busy, let from = position {
                let target = perch(on: next)?.point ?? from
                let distance = hypot(target.x - from.x, target.y - from.y)
                phase = .hopping(from: from, to: next, started: now, duration: DashiiMath.clamp(0.45 + distance / 1800, 0.55, 1.1))
            } else if gone, !busy {
                phase = .exiting(window, started: now)
            } else {
                phase = .perched(window)
                place(on: window, clip: .idle, age: 0)
            }
        case .hopping(let from, let window, let started, let duration):
            let window = refreshed(window)
            phase = .hopping(from: from, to: window, started: started, duration: duration)
            hop(from: from, to: window, progress: (now - started) / duration)
        case .exiting(let window, let started):
            let age = now - started
            if let front, age < 0.7 || age >= 2 {
                // Something came forward before letting go (or after the fall): climb onto it.
                phase = age < 0.7 ? .hopping(from: position ?? .zero, to: front, started: now, duration: 0.8) : .entering(front, started: now)
            } else if age >= 2 {
                phase = .free
                stage.climbClip = nil
                stage.contacts = []
                stage.edge = nil
                stage.motion.velocity = .zero
                goHome()
            } else {
                place(on: window, clip: .exit, age: age)
            }
        }
    }

    /// Windows slide off-screen while Spaces switch; those positions aren't real perches.
    private func mostlyOnScreen(_ window: FrontWindow) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKit = CGRect(x: window.frame.minX, y: primaryHeight - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        let visible = NSScreen.screens.map { appKit.intersection($0.frame) }.filter { !$0.isNull }.map { $0.width * $0.height }.reduce(0, +)
        return visible >= appKit.width * appKit.height * 0.6
    }

    /// The frontmost window once it has been in front for a moment.
    private func settledFront(now: Double) -> FrontWindow? {
        guard let front else { candidate = nil; return nil }
        if candidate?.window.id != front.id { candidate = (front, now) }
        return now - (candidate?.since ?? now) > 0.35 ? front : nil
    }

    /// The same window with its latest frame, so Dashii rides along as it moves or resizes.
    private func refreshed(_ window: FrontWindow) -> FrontWindow {
        if let front, front.id == window.id { return front }
        return window
    }

    private func space(for window: FrontWindow) -> PerchSpace? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let screen = PerchSpace.screen(for: window.frame, screens: NSScreen.screens.map(\.frame), primaryHeight: primaryHeight) else { return nil }
        return PerchSpace(screen: screen, primaryHeight: primaryHeight, scale: Self.scale)
    }

    /// Where Dashii sits on `window` (screen point) and the perch geometry.
    private func perch(on window: FrontWindow, clip: DashiiClip = .idle, age: Double = 0) -> (point: CGPoint, placement: DashiiPlacement, space: PerchSpace)? {
        guard let space = space(for: window) else { return nil }
        let placement = DashiiPlacement.compute(state: clip, time: age, target: space.rig(window.frame), viewport: space.viewport)
        return (space.screenPoint(placement.root), placement, space)
    }

    private func place(on window: FrontWindow, clip: DashiiClip, age: Double) {
        guard let (wanted, placement, _) = perch(on: window, clip: clip, age: age) else { return }
        let climbing: DashiiClip? = clip == .idle ? nil : clip
        if stage.climbClip != climbing { stage.climbClip = climbing }
        if stage.motion.airborne { stage.motion.airborne = false }
        let contacts = placement.contact
            ? placement.contacts.map { DashiiPlacement.Contact(side: $0.side, goal: CGPoint(x: $0.goal.x - placement.root.x, y: $0.goal.y - placement.root.y)) }
            : []
        if stage.contacts != contacts { stage.contacts = contacts }
        if stage.edge != placement.edge || loggedWindow != window.id {
            loggedWindow = window.id
            DashLog.info("Perching on window \(window.id) of pid \(window.pid) at \(window.frame), \(placement.edge.rawValue) edge", category: "mascot")
        }
        if stage.edge != placement.edge { stage.edge = placement.edge }
        if clip == .idle, let current = position {
            // Perched: a critically damped spring toward the spot, so riding a dragged window
            // trails smoothly instead of snapping.
            let dt = 1.0 / 60, stiffness = 140.0, damping = 2 * sqrt(stiffness)
            var vx = velocity.dx, vy = velocity.dy
            vx += ((wanted.x - current.x) * stiffness - vx * damping) * dt
            vy += ((wanted.y - current.y) * stiffness - vy * damping) * dt
            var next = CGPoint(x: current.x + vx * dt, y: current.y + vy * dt)
            if hypot(wanted.x - next.x, wanted.y - next.y) < 0.3 && hypot(vx, vy) < 2 { next = wanted; vx = 0; vy = 0 }
            if hypot(wanted.x - current.x, wanted.y - current.y) > 600 { next = wanted; vx = 0; vy = 0 }
            setRoot(next, velocity: CGVector(dx: vx, dy: vy))
        } else {
            setRoot(wanted, velocity: nil)
        }
    }

    /// One frame of the hop: an eased arc whose height grows with the distance, landing in a squash.
    private func hop(from: CGPoint, to window: FrontWindow, progress: Double) {
        guard let (target, placement, _) = perch(on: window) else { return }
        if progress >= 1 {
            stage.motion.landedAt = Date().timeIntervalSince(DashiiClock.epoch)
            stage.motion.airborne = false
            setRoot(target, velocity: .zero)
            phase = .perched(window)
            return
        }
        if !stage.motion.airborne { stage.motion.airborne = true }
        if stage.climbClip != nil { stage.climbClip = nil }
        if !stage.contacts.isEmpty { stage.contacts = [] }
        if stage.edge != placement.edge { stage.edge = placement.edge }
        let p = DashiiMath.smoother(progress)
        let distance = hypot(target.x - from.x, target.y - from.y)
        let lift = min(60 + distance * 0.25, 220) * sin(progress * .pi)
        // AppKit y is up: the arc goes up.
        setRoot(CGPoint(x: DashiiMath.mix(from.x, target.x, p), y: DashiiMath.mix(from.y, target.y, p) + lift), velocity: nil)
    }

    /// Moves the panel so the root lands on `point`, tracking the velocity for leaning.
    private func setRoot(_ point: CGPoint, velocity measured: CGVector?) {
        let previous = position ?? point
        position = point
        let dt = 1.0 / 60
        velocity = measured ?? CGVector(dx: (point.x - previous.x) / dt, dy: (point.y - previous.y) / dt)
        // Rig space is y down and in rig points.
        stage.motion.velocity = CGVector(dx: velocity.dx / Self.scale, dy: -velocity.dy / Self.scale)
        moveRoot(to: point)
    }

    /// Back to where Dashii lived before climbing, with a short glide.
    private func goHome() {
        guard let panel, let origin = freeOrigin else { return }
        animating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.8
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(origin)
        } completionHandler: {
            Task { @MainActor in
                self.animating = false
                self.position = self.center
            }
        }
    }

    // MARK: Roaming

    private func startRoaming(_ persona: Persona) {
        roamer?.cancel()
        guard persona.roams, !persona.climbsWindows else { return }
        roamer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 70...140)))
                self?.hop()
            }
        }
    }

    /// A short animated hop to a nearby spot, unless the user moved Dashii recently or a bubble is open.
    private func hop() {
        guard let panel, !busy, case .free = phase, Date().timeIntervalSince(lastManualMove) > 300,
              let screen = panel.screen?.visibleFrame else { return }
        var origin = panel.frame.origin
        origin.x += CGFloat.random(in: -220...220)
        origin.y += CGFloat.random(in: -60...60)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - panel.frame.height - 8)
        animating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.1
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(origin)
        } completionHandler: {
            Task { @MainActor in self.animating = false }
        }
    }
}

/// Bridges a display link's selector to a closure.
private final class DisplayLinkTarget: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @MainActor @objc func fire() { action() }
}
