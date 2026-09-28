import Foundation

// MARK: - Watch ⇄ iPhone payloads
//
// Small, display-ready value types shared by the iPhone app and the Apple
// Watch app. Text is already cleaned for a small screen on the iPhone
// (no tool calls, reasoning or code blocks). Nothing here carries credentials.

/// Everything the watch home screen needs, pushed via application context
/// and returned by the `snapshot` request.
nonisolated struct WatchSnapshot: Codable, Sendable, Equatable {
    var signedIn: Bool
    var serverName: String?
    var userName: String?
    var chats: [WatchChatSummary]
    var channels: [WatchChannelSummary]
    var models: [WatchModelSummary]
    var defaultModelId: String?
    var updatedAt: Date

    static let empty = WatchSnapshot(
        signedIn: false, serverName: nil, userName: nil,
        chats: [], channels: [], models: [], defaultModelId: nil, updatedAt: .distantPast
    )
}

nonisolated struct WatchChatSummary: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var title: String
    var updatedAt: Date
    var pinned: Bool
}

nonisolated struct WatchChannelSummary: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var name: String
    /// "channel" | "group" | "dm"
    var kind: String
    var canPost: Bool
}

nonisolated struct WatchModelSummary: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var name: String
}

nonisolated struct WatchIdRequest: Codable, Sendable {
    let id: String
}

nonisolated struct WatchMessage: Codable, Sendable, Hashable, Identifiable {
    let id: String
    /// "user" (you) | "assistant" | "other" (another channel member)
    var role: String
    var author: String?
    var text: String
    var date: Date
}

nonisolated struct WatchChatDetail: Codable, Sendable {
    let id: String
    var title: String
    var messages: [WatchMessage]
    /// True when older messages were left out to fit the watch.
    var truncated: Bool
}

nonisolated struct WatchChannelDetail: Codable, Sendable {
    let id: String
    var name: String
    var canPost: Bool
    var messages: [WatchMessage]
}

nonisolated struct WatchPostRequest: Codable, Sendable {
    let channelId: String
    let text: String
}

/// Watch → iPhone: send a typed / dictated prompt.
nonisolated struct WatchAskRequest: Codable, Sendable {
    let turnId: Int
    /// Continue this chat, or `nil` to start a new one.
    let chatId: String?
    let text: String
    /// Model for a new chat (`nil` = the server default).
    let modelId: String?
    /// Voice mode: asks the server for a spoken-style answer.
    let voice: Bool
    /// The reply should be read aloud (on the watch or the iPhone).
    let speak: Bool
    /// The watch wants the server voice: the iPhone prepares audio clips.
    let serverVoice: Bool
}

/// Watch → iPhone: the recorded utterance for `turnId` is complete.
nonisolated struct WatchVoiceEndRequest: Codable, Sendable {
    let turnId: Int
    let chatId: String?
    let modelId: String?
    /// Number of `audioChunk` messages sent for this turn (seq 0..<count).
    let messageCount: Int
    let speak: Bool
    let serverVoice: Bool
}

/// Watch → iPhone: one part of the server-voice clip for sentence `index`.
nonisolated struct WatchClipRequest: Codable, Sendable {
    let turnId: Int
    let index: Int
    let part: Int
}

nonisolated struct WatchTurnRequest: Codable, Sendable {
    let turnId: Int
    /// Only sentences from this index on are returned (saves bandwidth).
    var sentencesFrom: Int = 0
}

/// iPhone → watch: progress of one prompt → reply turn.
nonisolated struct WatchTurnState: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case transcribing, thinking, streaming, done, failed
    }

    let turnId: Int
    var phase: Phase
    /// What the user said / typed.
    var prompt: String?
    /// Reply so far, cleaned for display.
    var reply: String
    /// Complete speakable sentences, starting at `sentenceStart`.
    var sentences: [String]
    var sentenceStart: Int
    var chatId: String?
    var chatTitle: String?
    var error: String?
    /// The iPhone is reading the reply aloud (headphones connected to it),
    /// so the watch must not speak it too.
    var speaksOnPhone: Bool = false
    /// The iPhone is still playing the spoken reply.
    var phoneSpeaking: Bool = false
    /// Server-suggested follow-up questions (arrive shortly after `done`).
    var followUps: [String] = []
    /// Live words while the user is still speaking (voice turns, if the
    /// iPhone can transcribe as audio arrives).
    var partialTranscript: String?

    var isFinished: Bool { phase == .done || phase == .failed }
}

/// Watch → iPhone: open a chat's latest follow-up suggestions / the live
/// transcript of an in-progress voice turn. Reply: `turn` + `WatchTurnState`.
nonisolated struct WatchLiveRequest: Codable, Sendable {
    let turnId: Int
}
