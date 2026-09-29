import Foundation
import AVFoundation
import os.log

/// Drives one voice call: mic → VAD / turn detection → STT → chat → TTS → speaker.
///
/// **Echo is handled by construction, not by thresholds.** The call always
/// knows what it is playing and when that sound can still reach the mic
/// (`CallAudioPlayer.timeline`). Every decision uses that knowledge:
/// - while the AI is audible, mic audio is never treated as a user turn —
///   it only feeds barge-in detection;
/// - a barge-in is confirmed by *what was said* (words the AI didn't say),
///   never by loudness alone;
/// - a finished user turn that is only the AI's own recent words is dropped.
///
/// Every turn gets a new `turnId`; async work from an older turn checks it and
/// drops its result, so a late transcript or reply never leaks into a newer turn.
///
/// Split across files: this one (state + lifecycle), `+Turns` (listening and
/// end-of-turn), `+Reply` (reply playback and barge-in).
@MainActor
final class CallOrchestrator {

    enum Phase: Equatable {
        case idle, listening, processing, speaking, paused
    }

    let logger = Logger(subsystem: "com.openui", category: "CallOrchestrator")

    // MARK: - Components

    let audioEngine = CallAudioEngine()
    lazy var player = CallAudioPlayer(engine: audioEngine)
    let vad: VADPipeline
    let turnDetector: TurnDetector
    let bargeIn: BargeInDetector
    let bargeInEnabled: Bool
    var stt: CallSTTEngine
    var speech: CallSpeechPipeline!
    weak var chat: ChatViewModel?

    // MARK: - State

    var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            logger.info("[call] turn \(self.turnId) phase \(String(describing: oldValue)) → \(String(describing: self.phase))")
            onPhaseChanged?(phase)
        }
    }
    var turnId = 0
    var replyTask: Task<Void, Never>?
    var frameTask: Task<Void, Never>?
    var silenceTimer: Task<Void, Never>?
    var endingTurn = false
    var smartTurnInFlight = false
    var turnStartedAt = Date()
    /// Decides when a pause ends the user's turn (Smart Turn + pace setting).
    var endOfTurn: EndOfTurnPolicy
    /// Effective pause range (pace preset or the user's custom range).
    let pauseRange: PauseRange
    /// Label for logs ("balanced", "custom 0.6–4.0 s", …).
    let pauseLabel: String
    /// Smart Turn in use (loaded and enabled in Advanced settings).
    let smartTurnEnabled: Bool

    /// Model-free fallback (VAD off or unavailable): RMS level + silence timer.
    static let fallbackLevelThreshold: Float = 0.02
    var fallbackSilence: TimeInterval { pauseRange.fallbackSilence }
    var lastLoudAt: Date?
    var heardSpeechFallback = false
    /// Silero in use: loaded, enabled in Advanced settings, and healthy.
    /// Goes false for the rest of the call if it fails at runtime; turn-taking
    /// then uses the RMS fallback.
    lazy var sileroActive = vadEnabled && vad.hasSilero
    let vadEnabled: Bool

    /// How far back played sentences count as "just said" for echo matching.
    static let echoTextWindow: TimeInterval = 6
    /// Start (audio time) of the barge-in candidate being judged.
    var candidateStartedAt: Date?
    /// Recent mic frames for utterance engines (see `RecentFrames`).
    var recentFrames = RecentFrames()
    /// Mic audio of the current user turn (see `TurnAudio`).
    var turnAudio = TurnAudio()

    // MARK: - Outputs

    var onPhaseChanged: ((Phase) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onUserTurn: ((String) -> Void)?
    var onReplyText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// Live turn-taking readout (only when Diagnostics is on).
    var onDiagnostics: ((CallDiagnostics) -> Void)?
    let diagnosticsEnabled: Bool
    var diagnostics = CallDiagnostics() {
        didSet { if diagnosticsEnabled { onDiagnostics?(diagnostics) } }
    }

    /// Muting gates turn-taking: no audio reaches STT/VAD and no turn can
    /// start or end while muted. Replies keep playing.
    var isMicMuted: Bool {
        get { audioEngine.isMicMuted }
        set {
            guard newValue != audioEngine.isMicMuted else { return }
            audioEngine.isMicMuted = newValue
            logger.info("[call] mic \(newValue ? "muted" : "unmuted")")
            if phase == .listening { beginListening() }   // drop partial audio
        }
    }

    var sttDisplayName: String { stt.displayName }

    /// Engines that run MLX on the GPU (must not run while backgrounded).
    var usesGPUSTT: Bool { stt is MLXCallSTTEngine }
    var usesGPUTTS: Bool { currentTTS is MLXCallTTSEngine }

    /// The voice engine currently speaking replies.
    private(set) var currentTTS: CallTTSEngine
    /// What the current engines were built from (`CallEngineSelection`
    /// signatures) — compared against the wanted selection to decide swaps.
    var ttsSignature = ""
    var sttSignature = ""
    /// A listening engine waiting to take over at the next turn (swaps never
    /// happen while a finished turn is still being transcribed).
    var pendingSTT: (engine: CallSTTEngine, signature: String)?
    /// Fired after the voice or listening engine was swapped.
    var onEnginesChanged: (() -> Void)?

    init(
        stt: CallSTTEngine,
        tts: CallTTSEngine,
        vadStore: VADModelStore,
        settings: VoiceCallSettings,
        chat: ChatViewModel
    ) {
        self.stt = stt
        self.vad = VADPipeline.make(store: vadStore)
        self.turnDetector = TurnDetector(config: .preset(settings.vadSensitivity))
        if settings.customPauseEnabled {
            let r = settings.pauseRange
            self.pauseRange = .custom(min: r.min, max: r.max)
            self.pauseLabel = String(format: "custom %.1f–%.1f s", r.min, r.max)
        } else {
            self.pauseRange = PauseRange(settings.turnPace)
            self.pauseLabel = settings.turnPace.rawValue
        }
        self.endOfTurn = EndOfTurnPolicy(pace: pauseRange)
        self.vadEnabled = settings.vadEnabled
        self.smartTurnEnabled = settings.smartTurnEnabled
        self.bargeIn = BargeInDetector(
            sensitivity: settings.vadSensitivity,
            interruptAfter: settings.interruptAfter,
            echoMarginMultiplier: settings.echoProtection.marginMultiplier
        )
        // Barge-in needs neural voice detection to tell speech from noise.
        self.bargeInEnabled = settings.bargeInEnabled && settings.vadEnabled
        self.diagnosticsEnabled = settings.diagnosticsEnabled
        self.chat = chat
        self.currentTTS = tts
        self.speech = CallSpeechPipeline(player: player, engine: tts)
        speech.onStarted = { [weak self] in self?.speakingStarted() }
        speech.onFinished = { [weak self] in self?.speakingFinished() }
        audioEngine.onRebuilt = { [weak self] in
            self?.player.engineRebuilt()
            self?.audioRouteChanged()
        }
    }

    /// Swaps the voice. Unspoken sentences of a reply in progress continue
    /// on the new engine, so the switch is heard at a sentence boundary.
    func replaceTTS(_ newTTS: CallTTSEngine, signature: String) {
        speech.replaceEngine(newTTS)
        currentTTS = newTTS
        ttsSignature = signature
        logger.info("[call] TTS → \(newTTS.displayName, privacy: .public)")
        onEnginesChanged?()
    }
}
