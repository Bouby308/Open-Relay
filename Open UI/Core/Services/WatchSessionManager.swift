import Foundation
import UIKit
import WatchConnectivity
import os.log

/// iPhone end of the Watch ⇄ iPhone link.
///
/// **Auth safety:** this type never writes, refreshes or deletes credentials
/// and never calls sign-in / sign-out / session-restore code. The only
/// keychain access is a read-only existence check for the `ping` status.
/// Activated from `AppDelegate` at launch so a background wake from the
/// watch can be answered before any UI exists. Real work is done by
/// `WatchRelayService` on the main actor.
nonisolated final class WatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {

    static let shared = WatchSessionManager()

    private let logger = Logger(subsystem: "com.openui", category: "WatchLink")
    private let launchedAt = Date()
    private let lock = NSLock()
    private var messagesReceived = 0
    private var launchedInBackground = false

    private override init() { super.init() }

    /// Call once from `application(_:didFinishLaunchingWithOptions:)`.
    @MainActor
    func activate() {
        guard WCSession.isSupported() else { return }
        launchedInBackground = UIApplication.shared.applicationState == .background
        let session = WCSession.default
        session.delegate = self
        session.activate()
        logger.info("⌚️ WCSession activating (background launch: \(self.launchedInBackground))")
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        logger.info("⌚️ WCSession activation \(state.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        if state == .activated {
            Task { @MainActor in WatchRelayService.shared.refreshWatchIfNeeded() }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS when switching between multiple paired watches.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.isWatchAppInstalled else { return }
        Task { @MainActor in WatchRelayService.shared.refreshWatchIfNeeded() }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        lock.lock(); messagesReceived += 1; lock.unlock()
        guard let envelope = try? WatchEnvelope.decode(messageData) else {
            replyHandler(Self.errorReply("Unsupported message"))
            return
        }
        guard envelope.v == WatchProtocol.version else {
            replyHandler(Self.errorReply("Update Open Relay on your iPhone and watch to the same version."))
            return
        }
        let reply = SendableReply(replyHandler)
        if envelope.type == .ping {
            Task { @MainActor in
                let status = self.currentStatus()
                let pong = try? WatchEnvelope.make(.pong, payload: status, turn: envelope.turn, seq: envelope.seq)
                reply.send((try? pong?.encoded()) ?? Self.errorReply("Encode failed"))
            }
        } else {
            Task { @MainActor in
                reply.send(await WatchRelayService.shared.handle(envelope))
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func currentStatus() -> WatchPhoneStatus {
        let app = UIApplication.shared
        let state: String
        switch app.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        // Read-only existence check — never modifies the stored session.
        let readable = ServerConfigStore().activeServer.map {
            KeychainService.shared.hasToken(forServer: $0.url)
        } ?? false
        lock.lock(); let count = messagesReceived; lock.unlock()
        return WatchPhoneStatus(
            appState: state,
            protectedDataAvailable: app.isProtectedDataAvailable,
            sessionReadable: readable,
            launchedInBackground: launchedInBackground,
            secondsSinceLaunch: Date().timeIntervalSince(launchedAt),
            messagesReceived: count
        )
    }

    private static func errorReply(_ message: String) -> Data {
        (try? WatchEnvelope.make(.error, payload: WatchErrorPayload(message: message)).encoded()) ?? Data()
    }
}

/// Lets the WatchConnectivity reply handler cross into a main-actor task.
/// WatchConnectivity allows calling it from any thread, exactly once.
private nonisolated final class SendableReply: @unchecked Sendable {
    private let handler: (Data) -> Void
    init(_ handler: @escaping (Data) -> Void) { self.handler = handler }
    func send(_ data: Data) { handler(data) }
}
