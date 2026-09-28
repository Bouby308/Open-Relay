import Foundation
import WidgetKit

/// Writes `WidgetState` for the complications and asks WidgetKit to reload
/// only when something visible changed (reload budgets are limited).
@MainActor
enum WidgetBridge {

    private static var last: WidgetState?

    static func update(from snapshot: WatchSnapshot, lastChat: WatchStore.LastChat?, replyInProgress: Bool = false) {
        let latest = snapshot.chats.first
        let chat = lastChat.map { (id: $0.id, title: $0.title, preview: $0.preview, date: $0.date) }
            ?? latest.map { (id: $0.id, title: $0.title, preview: nil as String?, date: $0.updatedAt) }
        let state = WidgetState(signedIn: snapshot.signedIn,
                                chatId: snapshot.signedIn ? chat?.id : nil,
                                chatTitle: snapshot.signedIn ? chat?.title : nil,
                                preview: snapshot.signedIn ? chat?.preview.map { String($0.prefix(140)) } : nil,
                                updatedAt: chat?.date ?? snapshot.updatedAt,
                                replyInProgress: replyInProgress)
        let changed = last.map {
            $0.signedIn != state.signedIn || $0.chatId != state.chatId || $0.chatTitle != state.chatTitle
                || $0.preview != state.preview || $0.replyInProgress != state.replyInProgress
        } ?? true
        guard changed else { return }
        last = state
        state.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Shows / clears the "reply on its way" dot.
    static func setReplyInProgress(_ value: Bool) {
        let store = WatchStore.shared
        update(from: store.snapshot, lastChat: store.lastChat, replyInProgress: value)
    }
}
