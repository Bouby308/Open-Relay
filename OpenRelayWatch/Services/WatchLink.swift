import Foundation
import Observation
import WatchConnectivity
import os.log

/// Watch end of the Watch ⇄ iPhone link. Relay-only: sends requests to the
/// iPhone, which does all server work. Holds no credentials.
@MainActor @Observable
final class WatchLink: NSObject {

    static let shared = WatchLink()

    private(set) var activated = false
    private(set) var isReachable = false
    private(set) var companionInstalled = true
    /// Latest snapshot pushed by the iPhone via application context.
    private(set) var pushedSnapshot: WatchSnapshot?

    @ObservationIgnored let logger = Logger(subsystem: "com.openui.watch", category: "WatchLink")
    @ObservationIgnored private var activationWaiters: [CheckedContinuation<Void, Never>] = []

    func activate() {
        guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends one envelope and awaits the iPhone's reply envelope.
    /// Doesn't pre-check `isReachable` (it flickers); WatchConnectivity decides.
    func send(_ envelope: WatchEnvelope) async throws -> WatchEnvelope {
        await waitForActivation()
        let session = WCSession.default
        guard session.activationState == .activated else { throw LinkError.notActivated }
        let data = try envelope.encoded()
        let replyData: Data
        do {
            replyData = try await withCheckedThrowingContinuation { continuation in
                session.sendMessageData(data, replyHandler: { reply in
                    continuation.resume(returning: reply)
                }, errorHandler: { error in
                    continuation.resume(throwing: error)
                })
            }
        } catch {
            logger.info("send \(envelope.type.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw LinkError.unreachable
        }
        let reply = try WatchEnvelope.decode(replyData)
        switch reply.type {
        case .error:
            throw LinkError.failed((try? reply.payload(WatchErrorPayload.self).message) ?? "Something went wrong.")
        case .needsPhone:
            throw LinkError.needsPhone((try? reply.payload(WatchErrorPayload.self).message) ?? "Open Open Relay on your iPhone.")
        default:
            return reply
        }
    }

    /// Retries connection blips with a short backoff.
    func sendWithRetry(_ envelope: WatchEnvelope, attempts: Int = 3) async throws -> WatchEnvelope {
        var lastError: Error = LinkError.unreachable
        for attempt in 1...attempts {
            do {
                return try await send(envelope)
            } catch let error as LinkError where !error.isTransient {
                throw error
            } catch {
                lastError = error
                if attempt < attempts { try await Task.sleep(for: .milliseconds(300 * attempt)) }
            }
        }
        throw lastError
    }

    /// Typed request: encodes `payload`, decodes the reply payload as `R`.
    func request<P: Encodable, R: Decodable>(
        _ type: WatchMessageType, _ payload: P, as: R.Type, attempts: Int = 3
    ) async throws -> R {
        let reply = try await sendWithRetry(try WatchEnvelope.make(type, payload: payload), attempts: attempts)
        return try reply.payload(R.self)
    }

    private func waitForActivation() async {
        guard WCSession.isSupported(), WCSession.default.activationState != .activated else { return }
        activate()
        await withCheckedContinuation { continuation in
            activationWaiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.resumeWaiters()
            }
        }
    }

    private func resumeWaiters() {
        let waiters = activationWaiters
        activationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func refresh(_ session: WCSession) {
        activated = session.activationState == .activated
        isReachable = session.isReachable
        companionInstalled = session.isCompanionAppInstalled
        if activated { resumeWaiters() }
    }

    func receive(context: [String: Any]) {
        guard let data = context[WatchProtocol.snapshotContextKey] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        pushedSnapshot = snapshot
    }
}
