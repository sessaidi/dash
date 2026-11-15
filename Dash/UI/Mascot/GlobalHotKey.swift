import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// Open the mascot's ask bubble (global shortcut, menu bar).
    static let summonMascot = Notification.Name("DashSummonMascot")
    /// App-level commands from menus outside the main view (Dock menu, background menus).
    static let dashNewPage = Notification.Name("DashNewPage")
    static let dashNewSection = Notification.Name("DashNewSection")
    static let dashRenamePage = Notification.Name("DashRenamePage")
    static let dashAddWidget = Notification.Name("DashAddWidget")
}

/// A system-wide shortcut registered with Carbon's hot-key API (no Accessibility permission needed).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// ⌃⌥Space.
    static let description = "⌃⌥Space"
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() {
        guard reference == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .summonMascot, object: nil) }
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4441_5348), id: 1) // "DASH"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}

/// Keeps Dash running (with the mascot on the desktop and in the menu bar) after its window closes.
final class DashAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Preferences are saved a moment after they change; save what's pending before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        (DashDefaults.shared as? DatabaseDefaults)?.flush()
    }

    /// Right-click on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let persona = DashDefaults.shared.string(forKey: "persona.name").flatMap { $0.isEmpty || $0 == "Dot" ? nil : $0 } ?? "Dashii"
        for (title, name) in [("Ask \(persona)…", Notification.Name.summonMascot), ("New Page…", .dashNewPage), ("Add Widget…", .dashAddWidget)] {
            let item = NSMenuItem(title: title, action: #selector(post(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        return menu
    }

    @objc private func post(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? Notification.Name else { return }
        if name != .summonMascot { NSApp.activate() }
        NotificationCenter.default.post(name: name, object: nil)
    }
}
