import Foundation

// MARK: - Chat & channel detail

extension WatchRelayService {

    func chatDetail(_ id: String) async throws -> WatchChatDetail {
        let deps = try await ready()
        guard let manager = deps.conversationManager else { throw RelayError.bad("Not ready") }
        let conversation = try await manager.fetchConversation(id: id)
        let all = conversation.messages
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.isInternalMessage }
            .compactMap { msg -> WatchMessage? in
                let text = WatchTextFormatter.display(msg.content, limit: 1_500)
                guard !text.isEmpty else { return nil }
                return WatchMessage(id: msg.id, role: msg.role == .user ? "user" : "assistant",
                                    author: nil, text: text, date: msg.timestamp)
            }
        var kept = Array(all.suffix(16))
        var detail = WatchChatDetail(id: id, title: conversation.title, messages: kept, truncated: kept.count < all.count)
        // Stay well under the WatchConnectivity message limit.
        while kept.count > 1, Self.encodedSize(detail) > 18_000 {
            kept.removeFirst()
            detail = WatchChatDetail(id: id, title: conversation.title, messages: kept, truncated: true)
        }
        return detail
    }

    func channelDetail(_ id: String) async throws -> WatchChannelDetail {
        let deps = try await ready()
        guard let api = deps.apiClient else { throw RelayError.bad("Not ready") }
        async let channelTask = api.getChannel(id: id)
        async let messagesTask = api.getChannelMessages(id: id, skip: 0, limit: 20)
        let channel = try await channelTask
        let fetched = try await messagesTask
        let myId = deps.authViewModel.currentUser?.id
        // The API returns newest first.
        var kept = fetched.reversed().compactMap { msg -> WatchMessage? in
            let text = WatchTextFormatter.display(msg.content, limit: 800)
            guard !text.isEmpty else { return nil }
            let mine = msg.userId == myId
            return WatchMessage(id: msg.id, role: mine ? "user" : "other",
                                author: mine ? nil : (msg.user?.displayName ?? "Someone"),
                                text: text, date: msg.createdAt)
        }
        var detail = WatchChannelDetail(id: id, name: channel.displayName,
                                        canPost: channel.writeAccess ?? true, messages: kept)
        while kept.count > 1, Self.encodedSize(detail) > 18_000 {
            kept.removeFirst()
            detail.messages = kept
        }
        return detail
    }

    func postToChannel(_ req: WatchPostRequest) async throws {
        let deps = try await ready()
        guard let api = deps.apiClient else { throw RelayError.bad("Not ready") }
        let text = req.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RelayError.bad("Nothing to send") }
        _ = try await api.postChannelMessage(channelId: req.channelId, content: text, tempId: UUID().uuidString)
    }
}
