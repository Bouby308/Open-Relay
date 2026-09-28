import Foundation
import WatchConnectivity

// MARK: - Snapshot, chats, channels

extension WatchRelayService {

    func buildSnapshot() async -> WatchSnapshot {
        guard let deps = try? await ready(), let manager = deps.conversationManager else {
            var empty = WatchSnapshot.empty
            empty.updatedAt = Date()
            return empty
        }
        let api = manager.apiClient
        let store = deps.activeChatStore
        async let recentTask = try? manager.fetchConversationsPage(page: 1)
        async let pinnedTask = try? api.getPinnedConversations()
        async let channelsTask = try? api.getChannels()
        var models = store.cachedModels
        if models.isEmpty { models = (try? await manager.fetchModels()) ?? [] }
        var defaultModel = store.cachedDefaultModelId
        if defaultModel == nil { defaultModel = await manager.fetchDefaultModel() }
        let recent = await recentTask ?? []
        let pinned = await pinnedTask ?? []
        let channels = await channelsTask ?? []

        var seen = Set<String>()
        var chats: [WatchChatSummary] = []
        for conv in pinned + recent where seen.insert(conv.id).inserted {
            chats.append(WatchChatSummary(id: conv.id, title: conv.title, updatedAt: conv.updatedAt, pinned: conv.pinned))
            if chats.count >= 20 { break }
        }
        let channelList = channels
            .filter { !$0.isHiddenDM && $0.archivedAt == nil }
            .prefix(20)
            .map { WatchChannelSummary(id: $0.id, name: $0.displayName, kind: $0.type.rawValue, canPost: $0.writeAccess ?? true) }

        return WatchSnapshot(
            signedIn: true,
            serverName: deps.serverConfigStore.activeServer?.name,
            userName: deps.authViewModel.currentUser?.displayName,
            chats: chats,
            channels: Array(channelList),
            models: models.prefix(40).map { WatchModelSummary(id: $0.id, name: $0.name) },
            defaultModelId: defaultModel,
            updatedAt: Date()
        )
    }

    /// Keeps the watch's home screen fresh without it having to ask.
    func pushContext(_ snapshot: WatchSnapshot) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? session.updateApplicationContext([WatchProtocol.snapshotContextKey: data])
    }

    /// Refreshes the watch snapshot (e.g. when the iPhone app comes to the front).
    func refreshWatchIfNeeded() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        Task { pushContext(await buildSnapshot()) }
    }

    static func encodedSize<T: Encodable>(_ value: T) -> Int {
        (try? JSONEncoder().encode(value).count) ?? 0
    }
}

// MARK: - Display text

/// Turns raw assistant markdown into text that reads well on a watch:
/// tool calls, reasoning and code blocks are removed or replaced by a hint.
enum WatchTextFormatter {
    static func display(_ raw: String, limit: Int) -> String {
        var text = ToolCallParser.parseAll(raw).cleanedContent
        text = TTSTextPreprocessor.removeThinkingBlocks(text)
        text = TTSTextPreprocessor.regexReplace(text, pattern: "(?s)```.*?```", with: "\n[Code — open on iPhone]\n")
        if let open = text.range(of: "```") {
            text = String(text[..<open.lowerBound]) + "\n[Code — open on iPhone]"
        }
        text = TTSTextPreprocessor.regexReplace(text, pattern: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "[Image]")
        text = TTSTextPreprocessor.regexReplace(text, pattern: "\n{3,}", with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > limit {
            text = String(text.prefix(limit)) + "…\n\n[Continued on iPhone]"
        }
        return text
    }
}
