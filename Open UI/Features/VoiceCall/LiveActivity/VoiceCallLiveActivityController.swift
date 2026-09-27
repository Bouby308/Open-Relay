import ActivityKit
import Foundation
import os.log

/// Drives the voice-call Live Activity (Dynamic Island + Lock Screen).
///
/// Started when the call connects, updated only when the phase or mute state
/// actually changes (the elapsed timer renders itself), and ended with the
/// call. Also forwards the Mute / End buttons from the activity to the call.
@MainActor
final class VoiceCallLiveActivityController {

    typealias Phase = VoiceCallActivityAttributes.Phase

    private let logger = Logger(subsystem: "com.openui", category: "VoiceCallLiveActivity")
    private var activity: Activity<VoiceCallActivityAttributes>?
    private var lastState: VoiceCallActivityAttributes.ContentState?
    private var observers: [NSObjectProtocol] = []

    var onToggleMute: (() -> Void)?
    var onEndCall: (() -> Void)?

    /// Ends any activity left over from a previous run (e.g. the app was killed mid-call).
    static func endStaleActivities() {
        Task {
            for activity in Activity<VoiceCallActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func start(modelName: String, startDate: Date, phase: Phase, isMuted: Bool) {
        installObservers()
        guard activity == nil else {
            update(phase: phase, isMuted: isMuted)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities disabled by the user — skipping")
            return
        }
        let attributes = VoiceCallActivityAttributes(
            modelName: modelName.isEmpty ? "AI Assistant" : modelName,
            startDate: startDate
        )
        let state = VoiceCallActivityAttributes.ContentState(phase: phase, isMuted: isMuted)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
        } catch {
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(phase: Phase, isMuted: Bool) {
        guard let activity else { return }
        let state = VoiceCallActivityAttributes.ContentState(phase: phase, isMuted: isMuted)
        guard state != lastState else { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: VoiceCallActivityNotification.toggleMute, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onToggleMute?() }
            },
            center.addObserver(forName: VoiceCallActivityNotification.endCall, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onEndCall?() }
            },
        ]
    }
}
