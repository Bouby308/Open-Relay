import Foundation

/// How long the user may pause before their turn ends.
///
/// Separate from `VADSensitivity` (which is about detecting speech in noise):
/// a quiet room shouldn't make the assistant impatient.
enum TurnPace: String, CaseIterable, Sendable {
    case quick, balanced, relaxed

    var displayName: String {
        switch self {
        case .quick:    return "Quick"
        case .balanced: return "Balanced (default)"
        case .relaxed:  return "Relaxed"
        }
    }

    /// Shortest pause that can end a turn (Smart Turn fully confident).
    var minPause: TimeInterval {
        switch self { case .quick: 0.3; case .balanced: 0.5; case .relaxed: 0.8 }
    }

    /// Longest pause before the turn ends regardless of Smart Turn.
    var maxPause: TimeInterval {
        switch self { case .quick: 1.8; case .balanced: 3.0; case .relaxed: 4.5 }
    }

    /// Silence that ends a turn when no VAD models are available.
    var fallbackSilence: TimeInterval {
        switch self { case .quick: 1.0; case .balanced: 1.5; case .relaxed: 2.2 }
    }
}

/// How long the user may pause before their turn ends — preset or custom.
struct PauseRange: Sendable, Equatable {
    /// Shortest pause that can end a turn (Smart Turn fully confident).
    let minPause: TimeInterval
    /// Longest pause before the turn ends regardless of Smart Turn.
    let maxPause: TimeInterval
    /// Silence that ends a turn when Smart Turn isn't used.
    let fallbackSilence: TimeInterval

    init(min: TimeInterval, max: TimeInterval, fallbackSilence: TimeInterval) {
        self.minPause = min
        self.maxPause = Swift.max(max, min)
        self.fallbackSilence = Swift.min(Swift.max(fallbackSilence, min), self.maxPause)
    }

    init(_ pace: TurnPace) {
        self.init(min: pace.minPause, max: pace.maxPause, fallbackSilence: pace.fallbackSilence)
    }

    /// Custom range: fallback silence sits halfway, like the presets.
    static func custom(min: TimeInterval, max: TimeInterval) -> PauseRange {
        PauseRange(min: min, max: max, fallbackSilence: min + (max - min) * 0.4)
    }
}

/// Decides when a pause ends the user's turn, LiveKit-style: the less sure
/// Smart Turn is that the user has finished, the longer we wait.
///
///     requiredPause = minPause + (maxPause − minPause) × (1 − p)
///
/// Smart Turn is re-evaluated on the whole turn roughly every
/// `reevaluateInterval` while the user stays quiet (its authors recommend
/// re-running it with more context rather than judging once), and the
/// latest verdict sets the required pause. `maxPause` always ends the turn.
///
/// Pure logic: fed the current pause length and Smart Turn results.
struct EndOfTurnPolicy: Sendable {

    enum Decision: Equatable, Sendable {
        /// Keep listening.
        case wait
        /// Run Smart Turn on the turn audio now.
        case evaluate
        /// The user has finished.
        case endTurn
    }

    /// First Smart Turn check after this much silence.
    static let firstCheck: TimeInterval = 0.25
    /// Re-check this often while the pause continues.
    static let reevaluateInterval: TimeInterval = 0.4

    let pace: PauseRange
    /// Latest Smart Turn end-of-turn probability for this pause (nil = none yet).
    private(set) var lastProbability: Float?
    private var lastEvaluatedAtPause: TimeInterval?
    private var evaluationPending = false

    init(pace: PauseRange) { self.pace = pace }
    init(pace: TurnPace) { self.pace = PauseRange(pace) }

    /// Pause required to end the turn for Smart Turn probability `p`.
    func requiredPause(for p: Float) -> TimeInterval {
        let c = Double(min(max(p, 0), 1))
        return pace.minPause + (pace.maxPause - pace.minPause) * (1 - c)
    }

    /// Required pause given what we know now (max pause until evaluated).
    var currentRequiredPause: TimeInterval {
        lastProbability.map(requiredPause(for:)) ?? pace.maxPause
    }

    /// The user spoke again: forget this pause.
    mutating func speechResumed() {
        lastProbability = nil
        lastEvaluatedAtPause = nil
        evaluationPending = false
    }

    /// Called as the pause grows (every VAD chunk). `smartTurnAvailable` is
    /// false when the model isn't loaded — then silence alone decides.
    mutating func update(pause: TimeInterval, smartTurnAvailable: Bool) -> Decision {
        if pause >= pace.maxPause { return .endTurn }
        guard smartTurnAvailable else {
            return pause >= pace.fallbackSilence ? .endTurn : .wait
        }
        if let p = lastProbability, pause >= requiredPause(for: p) { return .endTurn }
        guard !evaluationPending, pause >= Self.firstCheck else { return .wait }
        if let last = lastEvaluatedAtPause, pause - last < Self.reevaluateInterval { return .wait }
        evaluationPending = true
        lastEvaluatedAtPause = pause
        return .evaluate
    }

    /// A Smart Turn result arrived for the current pause (nil = model failed).
    /// Returns `.endTurn` if the pause already satisfies the new verdict.
    mutating func smartTurnResult(_ p: Float?, pause: TimeInterval) -> Decision {
        evaluationPending = false
        guard let p else { return pause >= pace.fallbackSilence ? .endTurn : .wait }
        lastProbability = p
        return pause >= requiredPause(for: p) ? .endTurn : .wait
    }
}
