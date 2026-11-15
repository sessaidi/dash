import AppKit
import DashKit
import Foundation
import UserNotifications

/// Posts macOS notifications for events that need the user while Dash isn't in front.
/// Actions: "Ask <name>" (the mascot explains the event) and "Open" (the event's link, or Dash).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static let category = "dash.event"
    static let askAction = "dash.ask"
    static let openAction = "dash.open"

    /// Last notification per event kind, to avoid storms.
    private var lastSent: [String: Date] = [:]
    private let throttle: TimeInterval = 120
    private var authorized: Bool?
    private weak var persona: Persona?

    func start(activity: ActivityLog, persona: Persona) {
        self.persona = persona
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let ask = UNNotificationAction(identifier: Self.askAction, title: "Ask \(persona.name)", options: [])
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [ask, open], intentIdentifiers: [])])
        activity.onEmit { [weak self] event in
            MainActor.assumeIsolated { self?.consider(event) }
        }
    }

    /// Notify for critical events (and notable ones when tips are set to "everything"), only while
    /// Dash isn't the active app, at most once per event kind every two minutes.
    nonisolated static func shouldNotify(_ event: ActivityEvent, enabled: Bool, chattiness: Persona.Chattiness,
                                         appActive: Bool, lastSent: Date?, now: Date = Date(), throttle: TimeInterval = 120) -> Bool {
        guard enabled, !appActive else { return false }
        let minimum: ActivityEvent.Importance = chattiness == .everything ? .notable : .critical
        guard event.importance >= minimum else { return false }
        if let lastSent, now.timeIntervalSince(lastSent) < throttle { return false }
        return true
    }

    private func consider(_ event: ActivityEvent) {
        guard let persona, Self.shouldNotify(event, enabled: persona.notifications, chattiness: persona.chattiness,
                                             appActive: NSApp.isActive, lastSent: lastSent[event.kind], throttle: throttle) else { return }
        lastSent[event.kind] = Date()
        Task { await post(event, from: persona.name) }
    }

    /// A notification right now, from a hook (no throttling, shown even while Dash is in front).
    func notifyNow(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            if authorized == nil { authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = Self.category
            try? await center.add(UNNotificationRequest(identifier: "dash.hook.\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    private func post(_ event: ActivityEvent, from name: String) async {
        let center = UNUserNotificationCenter.current()
        if authorized == nil {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            DashLog.info("Notifications \(authorized == true ? "allowed" : "not allowed")", category: "notifications")
        }
        guard authorized == true else { return }
        let content = UNMutableNotificationContent()
        content.title = event.importance == .critical ? "\(name): this needs you" : name
        content.body = event.title + (event.detail.map { " — \($0)" } ?? "")
        content.sound = event.importance == .critical ? .default : nil
        content.categoryIdentifier = Self.category
        content.userInfo = ["title": event.title, "detail": event.detail ?? "", "link": event.link ?? ""]
        let request = UNNotificationRequest(identifier: "dash.\(event.id)", content: content, trigger: nil)
        do { try await center.add(request) } catch {
            DashLog.error("Couldn't post a notification: \(error.localizedDescription)", category: "notifications")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let title = info["title"] as? String ?? ""
        let detail = info["detail"] as? String ?? ""
        let link = info["link"] as? String ?? ""
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.openAction:
                if let url = URL(string: link), !link.isEmpty { NSWorkspace.shared.open(url) } else { DesktopMascot.shared.bringDashForward() }
            case Self.askAction, UNNotificationDefaultActionIdentifier:
                // The mascot explains it in its bubble.
                NotificationCenter.default.post(name: .summonMascot, object: "Tell me what I should know about this: \(title)\(detail.isEmpty ? "" : ". \(detail)")")
            default:
                break
            }
        }
    }

    /// Show banners even when Dash is active (rare: we only post while it isn't).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
