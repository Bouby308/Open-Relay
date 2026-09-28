import Foundation
import UIKit
import os.log

/// Does the work for the Apple Watch app. The watch is a remote: every
/// server call happens here, with the session the iPhone already has.
///
/// **Auth safety:** this service only *reads* auth state. It never signs in,
/// signs out, restores a session, refreshes or stores a token. If the app
/// isn't signed in it answers `needsPhone` so the watch can say so.
///
/// Split across files: `+Content` (snapshot, chats, channels), `+Ask`
/// (prompt → reply turns), `+Voice` (watch mic audio → transcript).
@MainActor
final class WatchRelayService {

    static let shared = WatchRelayService()

    /// UserDefaults key for Settings → Apple Watch → "Allow Apple Watch".
    static let enabledKey = "watch.relayEnabled"

    /// Set by `AppDependencyContainer.init`, which runs at process launch —
    /// including a background launch caused by a watch message.
    weak var dependencies: AppDependencyContainer? {
        didSet { observeAuthState() }
    }

    /// Last signed-in identity pushed to the watch (server + user).
    private var lastAuthKey: String?

    /// Watches (read-only) for sign-in / sign-out / account or server
    /// switches and pushes a fresh snapshot so the watch never shows the
    /// previous account's chats.
    private func observeAuthState() {
        guard let deps = dependencies else { return }
        withObservationTracking {
            _ = deps.authViewModel.phase
            _ = deps.authViewModel.currentUser?.id
            _ = deps.serverConfigStore.activeServer?.id
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.authStateChanged()
                self.observeAuthState()
            }
        }
    }

    private func authStateChanged() {
        guard let deps = dependencies else { return }
        let signedIn = deps.authViewModel.phase == .authenticated
        let key = signedIn
            ? "\(deps.serverConfigStore.activeServer?.id ?? "")|\(deps.authViewModel.currentUser?.id ?? "")"
            : "signed-out"
        guard key != lastAuthKey else { return }
        lastAuthKey = key
        turns.removeAll()
        watchChats.removeAll()
        refreshWatchIfNeeded()
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    let logger = Logger(subsystem: "com.openui", category: "WatchRelay")
    var turns: [Int: TurnRecord] = [:]
    var audio: [Int: [Int: Data]] = [:]
    /// View models for chats started from the watch (not in `ActiveChatStore`).
    var watchChats: [String: ChatViewModel] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var activeWork = 0

    private init() {}

    // MARK: - Types

    enum RelayError: LocalizedError {
        case needsPhone(String)
        case bad(String)
        var errorDescription: String? {
            switch self {
            case .needsPhone(let m), .bad(let m): return m
            }
        }
    }

    final class TurnRecord {
        var state: WatchTurnState
        var sentences: [String] = []
        /// The watch wants server-voice clips for this turn's sentences.
        var serverVoice = false
        var task: Task<Void, Never>?
        weak var chat: ChatViewModel?
        let createdAt = Date()
        init(state: WatchTurnState) { self.state = state }
    }

    /// Server-voice clips for the watch.
    static let clipMaker = WatchVoiceClipMaker()
    /// Live words while the user speaks on the watch.
    static let liveTranscriber = WatchLiveTranscriber()

    // MARK: - Entry point

    func handle(_ envelope: WatchEnvelope) async -> Data {
        do {
            return try await route(envelope).encoded()
        } catch RelayError.needsPhone(let message) {
            return Self.encode(.needsPhone, message)
        } catch {
            logger.error("⌚️ \(envelope.type.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return Self.encode(.error, Self.friendly(error))
        }
    }

    private func route(_ envelope: WatchEnvelope) async throws -> WatchEnvelope {
        switch envelope.type {
        case .snapshot:
            let snapshot = await buildSnapshot()
            pushContext(snapshot)
            return try WatchEnvelope.make(.snapshot, payload: snapshot)
        case .chat:
            let req = try envelope.payload(WatchIdRequest.self)
            return try WatchEnvelope.make(.chat, payload: try await chatDetail(req.id))
        case .channel:
            let req = try envelope.payload(WatchIdRequest.self)
            return try WatchEnvelope.make(.channel, payload: try await channelDetail(req.id))
        case .postChannel:
            try await postToChannel(try envelope.payload(WatchPostRequest.self))
            return try WatchEnvelope.make(.ok, payload: WatchEmpty())
        case .ask:
            let req = try envelope.payload(WatchAskRequest.self)
            return try WatchEnvelope.make(.turn, payload: try await startAsk(req))
        case .pollTurn:
            let req = try envelope.payload(WatchTurnRequest.self)
            return try WatchEnvelope.make(.turn, payload: try poll(req))
        case .cancelTurn:
            cancel(turnId: try envelope.payload(WatchTurnRequest.self).turnId)
            return try WatchEnvelope.make(.ok, payload: WatchEmpty())
        case .audioChunk:
            return try receiveAudio(envelope)
        case .voiceEnd:
            let req = try envelope.payload(WatchVoiceEndRequest.self)
            return try WatchEnvelope.make(.turn, payload: try await finishVoice(req))
        case .replyAudio:
            return try replyAudio(try envelope.payload(WatchClipRequest.self))
        case .liveTranscript:
            return try WatchEnvelope.make(.turn, payload: liveTranscript(try envelope.payload(WatchLiveRequest.self)))
        default:
            throw RelayError.bad("Unexpected \(envelope.type.rawValue)")
        }
    }

    static func encode(_ type: WatchMessageType, _ message: String) -> Data {
        (try? WatchEnvelope.make(type, payload: WatchErrorPayload(message: message)).encoded()) ?? Data()
    }

    private static func friendly(_ error: Error) -> String {
        if error is DecodingError { return "Update Open Relay on your iPhone and watch." }
        if let relay = error as? RelayError { return relay.localizedDescription }
        return "Couldn't reach your server. \(error.localizedDescription)"
    }
}


// MARK: - Readiness & background time

extension WatchRelayService {

    /// Read-only readiness check. Never triggers sign-in / restore / sign-out.
    func ready() async throws -> AppDependencyContainer {
        guard isEnabled else {
            throw RelayError.needsPhone("Apple Watch access is off. Turn it on in Open Relay → Settings → Apple Watch.")
        }
        // A background launch builds the container moments after the
        // message arrives — wait briefly for it.
        var deps = dependencies
        var waited = 0
        while deps == nil && waited < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
            deps = dependencies
        }
        guard let deps else { throw RelayError.needsPhone("Open Relay is starting on your iPhone. Try again.") }
        guard deps.authViewModel.phase == .authenticated,
              deps.authViewModel.isAuthenticated,
              deps.conversationManager != nil else {
            let locked = !UIApplication.shared.isProtectedDataAvailable
            throw RelayError.needsPhone(locked
                ? "Unlock your iPhone once, then try again."
                : "Open Open Relay on your iPhone and sign in.")
        }
        return deps
    }

    /// Keeps the app running in the background while a watch turn is in
    /// progress (the reply streams over the network).
    func beginWork() {
        activeWork += 1
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WatchRelay") { [weak self] in
            Task { @MainActor in self?.expireBackgroundTask() }
        }
    }

    func endWork() {
        activeWork = max(0, activeWork - 1)
        if activeWork == 0 { expireBackgroundTask() }
    }

    private func expireBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
