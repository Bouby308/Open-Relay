import Foundation

/// Predicts how loud the AI's own voice *should* be in the microphone at any
/// moment, so the call can tell the user apart from its echo by level —
/// the classic double-talk-detection idea used in telephony echo control.
///
/// The player records the level of every slice of TTS audio together with
/// the time it will actually leave the speaker. Expected echo at time *t* is
/// `coupling × max(played level in [t − window, t])`: the window absorbs the
/// acoustic path and timing uncertainty. `coupling` (how much of the speaker
/// survives voice processing into the mic) is learned while the AI talks and
/// the user doesn't, and persisted per route so each phone / room / accessory
/// adapts on its own — nothing is tuned to one device.
///
/// Pure logic (no audio APIs) so it's deterministic and unit-testable.
nonisolated struct EchoReference {

    struct Slice: Equatable {
        let start: Date
        let end: Date
        let level: Float
    }

    /// Echo can arrive this long after the sound is played.
    static let window: TimeInterval = 0.25
    /// Played audio kept for prediction.
    static let memory: TimeInterval = 4

    /// Coupling bounds: VP usually leaves −30…−10 dB of residual echo.
    static let minCoupling: Float = 0.01
    static let maxCoupling: Float = 1.0
    /// Starting point when nothing has been learned for a route.
    static let defaultCoupling: Float = 0.25

    private(set) var slices: [Slice] = []
    private(set) var coupling: Float
    private(set) var learnedSamples = 0

    init(coupling: Float = EchoReference.defaultCoupling) {
        self.coupling = min(max(coupling, Self.minCoupling), Self.maxCoupling)
    }

    // MARK: Playback side

    /// A slice of TTS audio of RMS `level` will play from `start` to `end`
    /// (already scaled by the player's current volume).
    mutating func played(level: Float, from start: Date, to end: Date) {
        guard end > start, level.isFinite else { return }
        slices.append(Slice(start: start, end: end, level: max(0, level)))
        let horizon = end.addingTimeInterval(-Self.memory)
        if let first = slices.first, first.end < horizon {
            slices.removeAll { $0.end < horizon }
        }
    }

    /// Playback was cut at `date`: nothing is audible after it.
    mutating func stopped(at date: Date) {
        slices.removeAll { $0.start >= date }
        if let last = slices.last, last.end > date {
            slices[slices.count - 1] = Slice(start: last.start, end: date, level: last.level)
        }
    }

    /// Volume changed (duck / unduck) from `date` on: rescale what's scheduled.
    mutating func rescale(by factor: Float, from date: Date) {
        guard factor.isFinite, factor >= 0 else { return }
        slices = slices.map { s in
            s.end <= date ? s : Slice(start: s.start, end: s.end, level: s.level * factor)
        }
    }

    // MARK: Mic side

    /// Loudest AI audio that can be reaching the mic at `date`.
    func playedLevel(at date: Date) -> Float {
        let from = date.addingTimeInterval(-Self.window)
        var peak: Float = 0
        for s in slices where s.end >= from && s.start <= date {
            peak = max(peak, s.level)
        }
        return peak
    }

    /// Mic level the AI's own voice is expected to produce at `date`.
    func expectedEcho(at date: Date) -> Float {
        coupling * playedLevel(at: date)
    }

    /// Learn coupling from a mic frame taken while the AI was audible and the
    /// user is believed silent. Tracks the upper envelope (echo peaks), rises
    /// fast and decays slowly so one quiet frame can't lower the guard.
    mutating func learn(micLevel: Float, at date: Date) {
        let played = playedLevel(at: date)
        guard played > 0.005, micLevel.isFinite, micLevel >= 0 else { return }
        let observed = min(max(micLevel / played, Self.minCoupling), Self.maxCoupling)
        learnedSamples += 1
        let alpha: Float = observed > coupling ? 0.3 : 0.02
        coupling += alpha * (observed - coupling)
        coupling = min(max(coupling, Self.minCoupling), Self.maxCoupling)
    }

    /// How far above the expected echo a mic level is (∞ when nothing plays).
    func ratioAboveEcho(micLevel: Float, at date: Date, noiseFloor: Float) -> Float {
        let expected = max(expectedEcho(at: date), noiseFloor)
        guard expected > 0 else { return .infinity }
        return micLevel / expected
    }
}

/// Persists learned echo coupling per output route so the next call on the
/// same phone + accessory starts already adapted.
enum EchoCouplingStore {
    private static func key(_ route: AudioRoute) -> String { "voiceCall.echoCoupling.\(route)" }

    static func load(_ route: AudioRoute, defaults: UserDefaults = .standard) -> Float {
        let v = defaults.float(forKey: key(route))
        return v > 0 ? v : EchoReference.defaultCoupling
    }

    static func save(_ coupling: Float, route: AudioRoute, defaults: UserDefaults = .standard) {
        defaults.set(coupling, forKey: key(route))
    }
}
