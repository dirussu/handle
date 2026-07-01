import AppKit
import UserNotifications

/// Posts macOS notifications when a long-running task completes while the chat
/// panel is dismissed. Tap the notification to reopen the chat.
@MainActor
final class NotificationsService {
    static let shared = NotificationsService()
    private init() {}

    static let actionOpenChat = "AKARI_OPEN_CHAT"
    static let categoryTaskComplete = "AKARI_TASK_COMPLETE"

    /// Request authorization (alert + sound). Safe to call repeatedly.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            print("[Akari] Notification auth error: \(error.localizedDescription)")
        }
        // Register category so taps route to a known action.
        let openAction = UNNotificationAction(
            identifier: Self.actionOpenChat,
            title: "Open chat",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryTaskComplete,
            actions: [openAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    func notifyTaskComplete(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Akari"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryTaskComplete

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Akari] Notification post error: \(error.localizedDescription)")
            }
        }
    }
}
