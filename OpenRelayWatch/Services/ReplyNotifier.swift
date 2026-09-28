import Foundation
@preconcurrency import UserNotifications
import WatchKit

/// The watch's own notifications: "Reply ready" when you lowered your wrist
/// or left Talk before the answer finished. Reply / Open actions.
@MainActor
final class ReplyNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = ReplyNotifier()

    nonisolated static let category = "watch.replyReady"
    nonisolated static let replyAction = "watch.reply"
    nonisolated static let openAction = "watch.open"

    /// Set by the app to open a chat (notification tap / Open).
    var onOpenChat: ((String, String) -> Void)?

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [reply, open], intentIdentifiers: [], options: [])
        ])
    }

    /// Asks once, the first time Talk is used.
    static func requestPermissionIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    static func replyReady(chatId: String?, title: String?, preview: String) {
        guard let chatId else { return }
        let content = UNMutableNotificationContent()
        content.title = title ?? "Reply ready"
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = text.count > 140 ? String(text.prefix(140)) + "…" : text
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = chatId
        content.userInfo = ["chatId": chatId, "title": title ?? "Chat"]
        let request = UNNotificationRequest(identifier: "reply-\(chatId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app is in front — the reply is already on screen.
        completionHandler(notification.request.content.categoryIdentifier == Self.category ? [] : [.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let chatId = info["chatId"] as? String
        let title = info["title"] as? String ?? "Chat"
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            if action == Self.replyAction, let chatId, let text {
                await Self.sendReply(text, chatId: chatId)
            } else if let chatId {
                self.onOpenChat?(chatId, title)
            }
            completionHandler()
        }
    }

    /// Sends a quick reply through the iPhone; the watch notifies again
    /// when the new answer is ready.
    private static func sendReply(_ text: String, chatId: String) async {
        let turn = TurnController(chatId: chatId, chatTitle: nil)
        turn.ask(text, modelId: nil, speak: false)
        for _ in 0..<120 where turn.isBusy {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if case .done = turn.phase, WKApplication.shared().applicationState != .active {
            replyReady(chatId: turn.chatId, title: turn.chatTitle, preview: turn.reply)
        }
    }
}
