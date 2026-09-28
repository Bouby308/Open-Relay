import Foundation
import WatchConnectivity

enum LinkError: LocalizedError {
    case notActivated, unreachable
    case needsPhone(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notActivated: return "Connecting to your iPhone…"
        case .unreachable: return "Can't reach your iPhone. Keep it nearby with Bluetooth on."
        case .needsPhone(let m), .failed(let m): return m
        }
    }

    /// Connection blips are worth retrying; server / sign-in problems aren't.
    var isTransient: Bool {
        switch self {
        case .notActivated, .unreachable: return true
        case .needsPhone, .failed: return false
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let box = ContextBox(session.receivedApplicationContext)
        Task { @MainActor in
            self.refresh(session)
            self.receive(context: box.value)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh(session) }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh(session) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let box = ContextBox(applicationContext)
        Task { @MainActor in self.receive(context: box.value) }
    }
}

/// Carries a property-list dictionary into a main-actor task.
private nonisolated final class ContextBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
