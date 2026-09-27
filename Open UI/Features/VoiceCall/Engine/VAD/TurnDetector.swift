import Foundation

/// Tracks speech and pauses within the user's turn from Silero probabilities.
///
/// It only *measures*: whether the user has started speaking, how much speech
/// the turn has, and how long the current pause is. Deciding when a pause
/// ends the turn is `EndOfTurnPolicy`'s job (Smart Turn + the user's pace
/// setting), so sensitivity (speech in noise) and patience stay independent.
///
/// No timers, no `Date` — driven by chunk counts, deterministic and testable.
/// One probability per `config.chunkDurationMs` chunk (512 samples @ 16 kHz).
final class TurnDetector {

    struct Config: Sendable {
        var chunkDurationMs: Double = 32
        /// Probability at/above which a chunk counts as speech.
        var speechProbThreshold: Float = 0.5
        /// Probability below which a chunk counts as silence. Chunks between
        /// the two thresholds neither extend speech nor count as pause.
        var silenceProbThreshold: Float = 0.35
        /// Consecutive speech needed before the turn counts as started.
        var speechConfirmMs: Double = 250
        /// A turn with less total speech than this is noise (a cough, a click).
        var minSpeechMs: Double = 300

        /// Sensitivity only changes how readily speech is detected in noise.
        static func preset(_ sensitivity: VADSensitivity) -> Config {
            switch sensitivity {
            case .low:
                return Config(speechProbThreshold: 0.6, silenceProbThreshold: 0.4, speechConfirmMs: 350)
            case .medium:
                return Config()
            case .high:
                return Config(speechProbThreshold: 0.4, silenceProbThreshold: 0.3, speechConfirmMs: 180)
            }
        }
    }

    enum Event: Sendable, Equatable {
        /// The user has started speaking (confirmed, not just a blip).
        case speechStarted
        /// The user was pausing and spoke again.
        case speechResumed
    }

    private(set) var config: Config
    private(set) var hasSpeech = false
    /// Total confirmed speech in this turn (ms).
    private(set) var speechDurationMs: Double = 0
    /// Length of the current pause since the last speech chunk (ms).
    private(set) var pauseMs: Double = 0

    private var aboveRunMs: Double = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Resets all counters for a new turn.
    func reset() {
        hasSpeech = false
        aboveRunMs = 0
        pauseMs = 0
        speechDurationMs = 0
    }

    /// Starts the turn as already speaking — used after a confirmed barge-in,
    /// where the user has been talking for a while before the turn began.
    func markSpeechInProgress() {
        reset()
        hasSpeech = true
        speechDurationMs = config.minSpeechMs
    }

    /// True when the turn had some speech but too little to count
    /// (e.g. a cough) — callers should discard it.
    var isTooShortToCount: Bool { hasSpeech && speechDurationMs < config.minSpeechMs }

    /// Current pause in seconds (0 while speaking or before speech).
    var pause: TimeInterval { hasSpeech ? pauseMs / 1000 : 0 }

    /// Feed one chunk's speech probability.
    @discardableResult
    func processChunk(probability: Float) -> [Event] {
        let dt = config.chunkDurationMs
        var events: [Event] = []

        if probability >= config.speechProbThreshold {
            aboveRunMs += dt
            if !hasSpeech, aboveRunMs >= config.speechConfirmMs {
                hasSpeech = true
                // Count the confirmation run as speech so a short "yes" counts.
                speechDurationMs = aboveRunMs - dt
                events.append(.speechStarted)
            } else if hasSpeech, pauseMs > 0 {
                events.append(.speechResumed)
            }
            if hasSpeech {
                speechDurationMs += dt
                pauseMs = 0
            }
        } else {
            aboveRunMs = 0
            // Ambiguous chunks (between thresholds) still extend the pause:
            // breathy trailing sounds shouldn't keep a turn open forever.
            // The end-of-turn policy + Smart Turn decide what the pause means.
            if hasSpeech { pauseMs += dt }
        }
        return events
    }
}

/// Voice-detection sensitivity presets shown in Settings.
enum VADSensitivity: String, CaseIterable, Sendable {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low:    return "Low (noisy places)"
        case .medium: return "Medium (default)"
        case .high:   return "High (quiet places)"
        }
    }
}
