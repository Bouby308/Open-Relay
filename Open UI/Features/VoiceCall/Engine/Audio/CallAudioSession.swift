import Foundation
import AVFoundation
import os.log

/// The single owner of `AVAudioSession` configuration for voice calls.
///
/// Previously `SpeechRecognitionService`, `ServerSpeechRecognitionService`,
/// `TextToSpeechService` and `VoiceCallViewModel` each configured the audio
/// session independently, occasionally fighting each other over category/mode.
/// `CallOrchestrator` now routes all session setup through this single object.
@MainActor
final class CallAudioSession {

    /// True while a voice call owns the shared session. Other audio services
    /// (read-aloud, TTS) must not deactivate it then — doing so kills the
    /// call's mic and, once the phone is locked, suspends the app.
    nonisolated static var isCallActive: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return _isCallActive }
        set { flagLock.lock(); _isCallActive = newValue; flagLock.unlock() }
    }
    nonisolated private static let flagLock = NSLock()
    nonisolated(unsafe) private static var _isCallActive = false

    private let logger = Logger(subsystem: "com.openui", category: "CallAudioSession")
    private(set) var isActive = false
    private(set) var isSpeakerOn = true

    /// Fired when the system reports a route change (e.g. AirPods connected/disconnected).
    var onRouteChange: ((AVAudioSession.RouteChangeReason) -> Void)?
    /// Fired on interruption begin/end (e.g. phone call, Siri).
    var onInterruption: ((AVAudioSession.InterruptionType) -> Void)?

    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    /// Activates the session in `.playAndRecord` / `.voiceChat` mode with the
    /// phone's built-in echo cancellation enabled. `.voiceChat` (not `.measurement`)
    /// is required for echo cancellation to stay on, which is what lets barge-in
    /// (interrupting the AI while it talks) work over the speaker.
    ///
    /// `.defaultToSpeaker` is deliberately NOT used: it makes the loudspeaker
    /// the session default, so choosing "iPhone" in the system route picker
    /// (or `overrideOutputAudioPort(.none)`) could never reach the earpiece.
    /// The speaker is applied as an explicit override instead — see `applyInitialRoute`.
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isActive = true
        Self.isCallActive = true
        installObserversIfNeeded()
        preferExternalInputIfAvailable()
        logger.info("Call audio session activated")
    }

    /// Routes to the loudspeaker (`true`) or clears the override (`false`),
    /// which lets the system use the earpiece or a connected headset / car.
    func setSpeakerOverride(_ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(on ? .speaker : .none)
            isSpeakerOn = on
        } catch {
            logger.error("Speaker override failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Picks the starting output: a connected headset / car always wins;
    /// otherwise the loudspeaker if `preferSpeaker`, else the earpiece.
    func applyInitialRoute(preferSpeaker: Bool) {
        if CallOutputRoute.hasExternalDevice() {
            setSpeakerOverride(false)
        } else {
            setSpeakerOverride(preferSpeaker)
        }
        preferExternalInputIfAvailable()
    }

    /// Uses the Bluetooth / car / headset microphone when one is connected, so
    /// the user is heard through the device they are listening on. Falls back
    /// to letting the system choose (built-in mic).
    func preferExternalInputIfAvailable() {
        let session = AVAudioSession.sharedInstance()
        let preferred: [AVAudioSession.Port] = [.carAudio, .bluetoothHFP, .headsetMic, .usbAudio]
        let inputs = session.availableInputs ?? []
        let external = preferred.lazy.compactMap { port in inputs.first { $0.portType == port } }.first
        // Leave the choice alone if it's already correct — setPreferredInput
        // triggers a route change (and an engine rebuild) every time.
        if session.preferredInput?.uid == external?.uid { return }
        do {
            try session.setPreferredInput(external)
            logger.info("Preferred input → \(external?.portName ?? "system default", privacy: .public)")
        } catch {
            logger.error("setPreferredInput failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-activates the session after an interruption (phone call, Siri).
    func reactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            isActive = true
        } catch {
            logger.error("Session reactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deactivate() {
        removeObservers()
        Self.isCallActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
        isActive = false
    }

    private func installObserversIfNeeded() {
        guard routeObserver == nil else { return }
        let center = NotificationCenter.default
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            Task { @MainActor in self.onRouteChange?(reason) }
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in self.onInterruption?(type) }
        }
    }

    private func removeObservers() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        routeObserver = nil
        interruptionObserver = nil
    }
}
