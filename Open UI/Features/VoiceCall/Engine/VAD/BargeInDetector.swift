import Foundation

/// Decides whether the user is really interrupting the AI.
///
/// VAD alone can't: coughs, "mm-hmm", sighs and the AI's own residual echo
/// all look like speech. Production agents (LiveKit adaptive interruption,
/// Pipecat min-words) combine several signals; this arbiter combines three
/// that are all computed on-device and work in any language:
///
/// 1. **Above-echo speech** — Silero says speech *and* the mic is clearly
///    louder than the AI's expected echo right now (`EchoReference`). Echo,
///    however it's transcribed, can't pass this.
/// 2. **Duration** — how long that above-echo speech has lasted. Coughs and
///    backchannels are short; interruptions aren't.
/// 3. **Novel words** — words the user said that the AI wasn't saying at
///    that moment (`EchoMatcher`).
///
/// Flow: `.duck` (cheap, reversible: lower the AI and listen closely) →
/// `.confirm` when the evidence is enough, or `.resume` when the user goes
/// quiet / the window expires without it. Pure logic, unit-testable.
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
        /// Novel (non-echo) words heard since the candidate started, or nil
        /// when the STT engine can't report words live.
        var novelWords: Int?
    }

    struct Config: Sendable, Equatable {
        var speechThreshold: Float
        /// Mic must be this many times the expected echo to count as the user.
        var echoMargin: Float
        /// Above-echo speech needed to duck.
        var duckMs: Double
        /// Minimum above-echo speech before any confirm.
        var minSpeechMs: Double
        /// Confirm with ≥ 2 novel words after `minSpeechMs`…
        var wordsForQuickConfirm: Int
        /// …or with ≥ 1 novel word after this much speech.
        var singleWordSpeechMs: Double
        /// Without live words: confirm after this much above-echo speech.
        var noWordsSpeechMs: Double
        /// With live words: confirm on this much above-echo speech even if the
        /// recogniser hasn't produced the user's words yet (it can lag).
        var sustainedSpeechMs: Double
        /// Resume after this much continuous non-speech inside a candidate.
        var resumeAfterSilenceMs: Double
        /// Hard cap on a candidate.
        var candidateTimeoutMs: Double
        var chunkMs: Double = 32

        static func preset(_ s: VADSensitivity) -> Config {
            switch s {
            case .low:
                return Config(speechThreshold: 0.75, echoMargin: 3.0, duckMs: 192, minSpeechMs: 450,
                              wordsForQuickConfirm: 2, singleWordSpeechMs: 650, noWordsSpeechMs: 1100,
                              sustainedSpeechMs: 1500, resumeAfterSilenceMs: 700, candidateTimeoutMs: 3000)
            case .medium:
                return Config(speechThreshold: 0.65, echoMargin: 2.2, duckMs: 160, minSpeechMs: 350,
                              wordsForQuickConfirm: 2, singleWordSpeechMs: 500, noWordsSpeechMs: 900,
                              sustainedSpeechMs: 1200, resumeAfterSilenceMs: 700, candidateTimeoutMs: 3000)
            case .high:
                return Config(speechThreshold: 0.55, echoMargin: 1.7, duckMs: 128, minSpeechMs: 300,
                              wordsForQuickConfirm: 2, singleWordSpeechMs: 420, noWordsSpeechMs: 750,
                              sustainedSpeechMs: 1000, resumeAfterSilenceMs: 700, candidateTimeoutMs: 3000)
            }
        }
    }

    enum Reason: String, Sendable {
        case words = "novel words", singleWord = "one word + speech", sustained = "sustained speech",
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
        if let s = interruptAfter {
            c.sustainedSpeechMs = s * 1000
            // Without live words, sustained speech is the only signal: keep
            // it at least as patient as the user asked, never quicker.
            c.noWordsSpeechMs = max(c.noWordsSpeechMs, min(s * 1000, c.noWordsSpeechMs * 1.5))
        }
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

        if let words = o.novelWords {
            if speechMs >= config.minSpeechMs, words >= config.wordsForQuickConfirm {
                return finish(.confirm, .words)
            }
            if speechMs >= config.singleWordSpeechMs, words >= 1 {
                return finish(.confirm, .singleWord)
            }
            // Safety net: the recogniser can lag behind live speech. Sustained
            // speech clearly above the expected echo is the user regardless —
            // the AI's own voice can't pass the echo gate, and coughs /
            // backchannels are far shorter than this.
            if speechMs >= config.sustainedSpeechMs {
                return finish(.confirm, .sustained)
            }
        } else if speechMs >= config.noWordsSpeechMs {
            return finish(.confirm, .sustained)
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

