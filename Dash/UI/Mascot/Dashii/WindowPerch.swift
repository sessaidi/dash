import AppKit
import Observation

/// What the desktop perch tells the mascot view: the climbing clip and where the hands grip.
@MainActor
@Observable
final class DashiiStage {
    /// "enter" or "exit" while climbing on or off a window; nil otherwise.
    var climbClip: DashiiClip?
    /// Hand goals relative to the root, in rig points.
    var contacts: [DashiiPlacement.Contact] = []
    /// A clip picked from the context menu, played once.
    var manualClip: DashiiClip?
    /// Perched on a window, on this edge.
    var edge: DashiiPlacement.Edge?
    /// The desktop bubble opens below Dashii (no room above) and/or to its right (no room left).
    var bubbleBelow = false
    var bubbleRight = false
    /// Per-frame motion for the renderer, not observed.
    @ObservationIgnored let motion = DashiiMotion()
}

/// The frontmost app's frontmost normal window, read from the window server. Window bounds come
/// without any permission (only titles need Screen Recording), so no Accessibility prompt.
struct FrontWindow: Equatable {
    let id: Int
    let pid: pid_t
    /// In Quartz coordinates: origin at the top-left of the primary display, y down.
    let frame: CGRect

    @MainActor
    static func current() -> FrontWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Dash's own surfaces (menus, popovers, the mascot) aren't windows to sit on; only its titled ones are.
        let own = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? Set(NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.isVisible }.map(\.windowNumber))
            : nil
        return pick(from: list, pid: app.processIdentifier, allowed: own)
    }

    /// The first (frontmost) ordinary window of `pid` that's big enough to sit on.
    /// `allowed` limits the pick to these window numbers (used for Dash itself).
    static func pick(from list: [[String: Any]], pid: pid_t, allowed: Set<Int>? = nil) -> FrontWindow? {
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 240, frame.height >= 160,
                  allowed?.contains(id) ?? true else { continue }
            return FrontWindow(id: id, pid: pid, frame: frame)
        }
        return nil
    }
}

/// Maps between Quartz window frames, a screen's rig space (y down, in rig points) and AppKit
/// screen coordinates (y up).
struct PerchSpace {
    /// The AppKit frame of the screen holding the window.
    let screen: CGRect
    /// Height of the primary display, which anchors Quartz coordinates.
    let primaryHeight: CGFloat
    let scale: CGFloat

    var viewport: CGSize { CGSize(width: screen.width / scale, height: screen.height / scale) }
    private var screenTop: CGFloat { primaryHeight - screen.maxY }

    func rig(_ quartz: CGRect) -> CGRect {
        CGRect(x: (quartz.minX - screen.minX) / scale, y: (quartz.minY - screenTop) / scale,
               width: quartz.width / scale, height: quartz.height / scale)
    }

    func screenPoint(_ rig: CGPoint) -> CGPoint {
        CGPoint(x: screen.minX + rig.x * scale, y: screen.maxY - rig.y * scale)
    }

    /// The screen showing most of the window, in AppKit coordinates.
    static func screen(for quartz: CGRect, screens: [CGRect], primaryHeight: CGFloat) -> CGRect? {
        let appKit = CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
        return screens.max { appKit.intersection($0).area < appKit.intersection($1).area }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
