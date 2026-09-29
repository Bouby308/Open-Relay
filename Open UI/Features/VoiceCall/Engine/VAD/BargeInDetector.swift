import Foundation

/// Decides whether the user is really interrupting the AI.
///
/// The user talking is the interruption — it doesn't wait for the words to
/// be recognised. Two on-device signals separate that from everything else:
///
/// 1. **Above-echo speech** — Silero says *speech* (not a tap, bump, music or
///    hum) *and* the mic is clearly louder than the AI's expected echo right
///    now (`EchoReference`), so the AI's own voice can't pass.
/// 2. **Duration** — about half a second of it. Coughs, clicks and "mm" are
///    shorter.
///
/// Words only act as a veto: if everything heard is the AI's own sentence
/// leaking back, it isn't an interruption.
///
/// Flow: `.duck` (cheap, reversible: lower the AI and listen closely) →
/// `.confirm` once the speech lasts, or `.resume` when the user goes quiet /
/// the window expires. Pure logic, unit-testable.
final class BargeInDetector {

    enum Event: Sendable, Equatable {
        /// Possible barge-in: duck the AI and start collecting the user's words.
        case duck
        /// The user is really talking: cancel the reply, keep their words.
        case confirm
        /// Not an interruption (cough, backchannel, echo, noise): restore volume.
        case resume
    }

    /// Everything known about one 32 ms chunk.
    struct Observation: Sendable, Equatable {
        /// Silero speech probability.
        var probability: Float
        /// Mic level ÷ expected echo level (∞ when nothing is playing).
        var ratioAboveEcho: Float
        /// Words heard since the candidate started that the AI wasn't saying,
        /// or nil when the STT engine can't report words live.
        var novelWords: Int?
        /// Words heard since the candidate started that match what the AI
        /// was saying at that moment (its own voice leaking into the mic).
        var echoWords: Int = 0
    }

    struct Config: Sendable, Equatable {
        var speechThreshold: Float
        /// Mic must be this many times the expected echo to count as the user.
        var echoMargin: Float
        /// Above-echo speech needed to duck.
        var duckMs: Double
        /// Above-echo speech that confirms the user is talking. The voice
        /// detector already separates speech from noise (taps, bumps, music,
        /// hum), and the echo gate rules out the AI's own voice — so this is
        /// enough. Short sounds like a cough stay below it.
        var confirmSpeechMs: Double
        /// Resume after this much continuous non-speech inside a candidate.
        var resumeAfterSilenceMs: Double
        /// Hard cap on a candidate.
        var candidateTimeoutMs: Double
        var chunkMs: Double = 32

        static func preset(_ s: VADSensitivity) -> Config {
            switch s {
            case .low:
                return Config(speechThreshold: 0.75, echoMargin: 3.0, duckMs: 192, confirmSpeechMs: 640,
                              resumeAfterSilenceMs: 700, candidateTimeoutMs: 3000)
            case .medium:
                return Config(speechThreshold: 0.65, echoMargin: 2.2, duckMs: 160, confirmSpeechMs: 480,
                              resumeAfterSilenceMs: 700, candidateTimeoutMs: 3000)
            case .high:
                return Config(speechThreshold: 0.55, echoMargin: 1.7, duckMs: 128, confirmSpeechMs: 380,
                              resumeAfterSilenceMs: 700, candidateTimeoutMs: 3000)
            }
        }
    }

    enum Reason: String, Sendable {
        case speech = "user speech", echo = "only the AI's own words",
             silence = "user went quiet", timeout = "timeout"
    }

    let config: Config
    fileprivate(set) var isMonitoring = false
    fileprivate(set) var isCandidate = false
    fileprivate(set) var lastReason: Reason?
    /// Above-echo speech / candidate length at the last decision (for logs).
    fileprivate(set) var lastSpeechMs: Double = 0
    fileprivate(set) var lastCandidateMs: Double = 0
    /// Above-echo speech accumulated in the current run / candidate (ms).
    fileprivate(set) var speechMs: Double = 0
    fileprivate var silenceMs: Double = 0
    fileprivate var candidateMs: Double = 0
    fileprivate var decided = false
    /// After a rejection, speech must pause this long before re-arming.
    static let rearmGapMs: Double = 250
    fileprivate var needsGap = false
    fileprivate var gapMs: Double = 0

    init(sensitivity: VADSensitivity) {
        config = .preset(sensitivity)
    }

    /// Preset for `sensitivity`, adjusted by the user's Advanced settings.
    init(sensitivity: VADSensitivity, interruptAfter: TimeInterval?, echoMarginMultiplier: Float) {
        var c = Config.preset(sensitivity)
        // "Talk over for" (Advanced) = how long you must talk to interrupt.
        if let s = interruptAfter { c.confirmSpeechMs = s * 1000 }
        c.echoMargin *= max(1, echoMarginMultiplier)
        config = c
    }
}

// MARK: - Feeding

extension BargeInDetector {

    func startMonitoring() {
        isMonitoring = true
        decided = false
        needsGap = false
        resetCandidate()
    }

    func stopMonitoring() {
        isMonitoring = false
        resetCandidate()
    }

    /// Feed one 32 ms chunk. Returns at most one event.
    func process(_ o: Observation) -> Event? {
        guard isMonitoring, !decided else { return nil }
        let dt = config.chunkMs
        let userSpeech = o.probability >= config.speechThreshold && o.ratioAboveEcho >= config.echoMargin

        guard isCandidate else {
            // After a rejection, sustained noise / speech (TV, music, a person
            // nearby) must pause before a new candidate — otherwise the AI's
            // volume would pump down and up continuously.
            if needsGap {
                gapMs = userSpeech ? 0 : gapMs + dt
                if gapMs < Self.rearmGapMs { return nil }
                needsGap = false
                speechMs = 0
            }
            // Idle: need a short run of above-echo speech (one 32 ms dip allowed).
            if userSpeech {
                speechMs += dt
                silenceMs = 0
            } else {
                silenceMs += dt
                if silenceMs > dt { speechMs = 0 }
            }
            guard speechMs >= config.duckMs else { return nil }
            isCandidate = true
            candidateMs = 0
            silenceMs = 0
            return .duck
        }

        candidateMs += dt
        if userSpeech {
            speechMs += dt
            silenceMs = 0
        } else {
            silenceMs += dt
        }

        if speechMs >= config.confirmSpeechMs {
            // Enough real speech. Only veto it when every word heard so far
            // is the AI's own sentence coming back through the mic.
            let novel = o.novelWords ?? 0
            if o.echoWords >= 2 && novel == 0 { return finish(.resume, .echo) }
            return finish(.confirm, .speech)
        }

        if silenceMs >= config.resumeAfterSilenceMs { return finish(.resume, .silence) }
        if candidateMs >= config.candidateTimeoutMs { return finish(.resume, .timeout) }
        return nil
    }

    private func finish(_ event: Event, _ reason: Reason) -> Event {
        lastReason = reason
        lastSpeechMs = speechMs
        lastCandidateMs = candidateMs
        if event == .confirm { decided = true }
        resetCandidate()
        if event == .resume {
            needsGap = true
            gapMs = reason == .silence ? Self.rearmGapMs : 0   // already quiet
        }
        return event
    }

    private func resetCandidate() {
        isCandidate = false
        speechMs = 0
        silenceMs = 0
        candidateMs = 0
    }
}

