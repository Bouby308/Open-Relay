import Foundation
import UIKit

// MARK: - Replying from a notification

extension WatchRelayService {

    /// Sends a reply typed/dictated in a notification (iPhone or Apple Watch).
    /// Channel replies are posted directly; chat replies go through the
    /// chat pipeline and wait (bounded) for the reply to finish so the usual
    /// "response ready" notification follows.
    func sendNotificationReply(_ text: String, conversationId: String?, channelId: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let deps = try? await readyIgnoringWatchSetting() else { return }
        beginWork()
        defer { endWork() }

        if let channelId, let api = deps.apiClient {
            _ = try? await api.postChannelMessage(channelId: channelId, content: trimmed, tempId: UUID().uuidString)
            return
        }
        guard let conversationId, let manager = deps.conversationManager else { return }
        let chat = deps.activeChatStore.viewModel(for: conversationId)
        if !chat.isConfigured {
            chat.configure(with: manager, socket: deps.socketService, store: deps.activeChatStore,
                           notes: deps.notesManager)
        }
        await chat.load()
        // Mark as backgrounded so the finished reply raises a notification.
        NotificationService.shared.bypassActiveConversationSuppression = true
        let send = Task { await chat.sendMessage(directText: trimmed) }
        // Bounded: the background task ends when the system says so anyway.
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { await send.value }
            group.addTask { try? await Task.sleep(for: .seconds(25)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Like `ready()`, but notification replies from the iPhone itself don't
    /// depend on the "Allow Apple Watch" switch.
    private func readyIgnoringWatchSetting() async throws -> AppDependencyContainer {
        var deps = dependencies
        var waited = 0
        while deps == nil && waited < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
            deps = dependencies
        }
        guard let deps, deps.authViewModel.phase == .authenticated, deps.conversationManager != nil else {
            throw RelayError.needsPhone("Not signed in")
        }
        return deps
    }
}
