import Foundation

// MARK: - Watch ⇄ iPhone wire protocol
//
// Shared by the iPhone app and the Apple Watch app (target membership).
//
// v1 is relay-only: the watch never carries auth credentials. Every server
// call happens on the iPhone with the session it already has, so nothing
// here can create, refresh or invalidate a token.

nonisolated enum WatchProtocol {
    /// Bumped on breaking wire-format changes.
    static let version = 3
    /// Soft cap for one `sendMessageData` payload (WatchConnectivity rejects
    /// oversized interactive messages).
    static let maxMessageBytes = 30_000
    /// 16 kHz mono Int16 — the format the call's STT engines already use.
    static let audioSampleRate: Double = 16_000
    /// 250 ms of 16 kHz Int16 mono audio = 8 000 bytes.
    static let audioChunkBytes = 8_000
    /// At most this many chunks are batched into one `audioChunk` message
    /// when the watch is catching up (16 KB raw ≈ 21 KB base64).
    static let maxChunksPerMessage = 2
    /// Application-context key carrying a JSON-encoded `WatchSnapshot`.
    static let snapshotContextKey = "snapshot"
    /// Handoff activity type for "continue this chat on iPhone".
    static let chatActivityType = "com.openui.openui.watch.chat"
    /// `userInfo` key in the Handoff activity holding the chat ID.
    static let chatActivityIdKey = "chatId"
    /// App group shared by the watch app and its complications/widgets.
    static let watchAppGroup = "group.com.openui.openui"
    /// Notification category on iPhone notifications that offers "Reply".
    static let replyActionId = "watch.reply"
}

nonisolated enum WatchMessageType: String, Codable, Sendable {
    /// Watch → iPhone: liveness / wake check. Reply: `pong` + `WatchPhoneStatus`.
    case ping
    case pong
    /// Watch → iPhone: request the home data. Reply: `snapshot` + `WatchSnapshot`.
    case snapshot
    /// Watch → iPhone: `WatchIdRequest`. Reply: `chat` + `WatchChatDetail`.
    case chat
    /// Watch → iPhone: `WatchIdRequest`. Reply: `channel` + `WatchChannelDetail`.
    case channel
    /// Watch → iPhone: `WatchPostRequest`. Reply: `ok`.
    case postChannel
    /// Watch → iPhone: `WatchAskRequest`. Reply: `turn` + `WatchTurnState`.
    case ask
    /// Watch → iPhone: `WatchTurnRequest`. Reply: `turn` + `WatchTurnState`.
    case pollTurn
    /// Watch → iPhone: `WatchTurnRequest`. Reply: `ok`.
    case cancelTurn
    /// iPhone → watch: current state of a turn.
    case turn
    /// Watch → iPhone: raw 16 kHz Int16 mono PCM in `body`; `turn` + `seq`
    /// identify it. Reply: `audioAck`.
    case audioChunk
    case audioAck
    /// Watch → iPhone: `WatchVoiceEndRequest` — the utterance is complete.
    /// Reply: `turn` + `WatchTurnState` (phase `transcribing`).
    case voiceEnd
    /// Watch → iPhone: `WatchClipRequest` — server-voice audio for one reply
    /// sentence. Reply: `replyAudio` with raw AAC (m4a) bytes in `body` and
    /// the total part count in `seq` (`seq == 0` = still being made).
    case replyAudio
    /// Watch → iPhone: `WatchLiveRequest` — live words of the voice turn
    /// currently being recorded. Reply: `turn` + `WatchTurnState`.
    case liveTranscript
    /// Generic success reply.
    case ok
    /// iPhone → watch: Open Relay on the iPhone isn't signed in / ready.
    /// Payload: `WatchErrorPayload`.
    case needsPhone
    /// Either direction: unknown / invalid request.
    case error
}

/// One message on the wire. `body` holds a JSON payload, or raw bytes for
/// `audioChunk`.
nonisolated struct WatchEnvelope: Codable, Sendable {
    var v: Int = WatchProtocol.version
    var id: UUID = UUID()
    let type: WatchMessageType
    /// Increasing per watch session; stale turns are dropped by the receiver.
    var turn: Int?
    /// Ordering within a turn (audio chunks, reply audio).
    var seq: Int?
    var sentAt: Date = Date()
    var body: Data = Data()

    init(type: WatchMessageType, turn: Int? = nil, seq: Int? = nil, body: Data = Data()) {
        self.type = type
        self.turn = turn
        self.seq = seq
        self.body = body
    }

    /// Builds an envelope with a JSON-encoded payload.
    static func make<T: Encodable>(
        _ type: WatchMessageType, payload: T, turn: Int? = nil, seq: Int? = nil
    ) throws -> WatchEnvelope {
        WatchEnvelope(type: type, turn: turn, seq: seq, body: try JSONEncoder().encode(payload))
    }

    func payload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> WatchEnvelope {
        try JSONDecoder().decode(WatchEnvelope.self, from: data)
    }
}

/// iPhone → watch reply to `ping`. Diagnostic only — contains no credentials.
nonisolated struct WatchPhoneStatus: Codable, Sendable {
    /// "active" | "inactive" | "background"
    let appState: String
    /// False while the iPhone is locked with data protection engaged.
    let protectedDataAvailable: Bool
    /// Whether the iPhone could *read* (never modify) its stored session.
    let sessionReadable: Bool
    /// True when this process was launched in the background (woken by the watch).
    let launchedInBackground: Bool
    let secondsSinceLaunch: Double
    let messagesReceived: Int
}

nonisolated struct WatchAudioAck: Codable, Sendable {
    let seq: Int
    let bytes: Int
}

nonisolated struct WatchErrorPayload: Codable, Sendable {
    let message: String
}

/// Payload for requests that carry no data.
nonisolated struct WatchEmpty: Codable, Sendable {
    init() {}
}
