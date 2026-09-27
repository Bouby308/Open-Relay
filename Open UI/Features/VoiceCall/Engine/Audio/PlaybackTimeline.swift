import Foundation

/// The call's record of what the AI has actually played through the speaker
/// and when that sound can still reach the microphone.
///
/// This is the single source of truth every turn-taking decision is made
/// against: echo cancellation on phones is imperfect (Apple's voice
/// processing is output subtraction, not a full adaptive AEC), so the call
/// must *know* when its own voice may be in the mic and *what* it said,
/// instead of guessing from levels.
///
/// - `isAIAudible(at:)` — true while audio is playing or inside the echo tail
///   (acoustic decay + route latency) after it stops.
/// - `recentSpokenText(within:)` — the words the AI actually played recently,
///   used to recognise its own voice in transcripts.
///
/// Pure value logic (no audio APIs) so it's deterministic and unit-testable.
nonisolated struct PlaybackTimeline {

    /// Extra time after the last sample leaves the speaker during which the
    /// AI's voice can still be picked up (room reverb + VP adaptation +
    /// output route latency). Loudspeaker rooms are the worst case.
    struct Tail: Equatable {
        var acoustic: TimeInterval
        var routeLatency: TimeInterval
        var total: TimeInterval { acoustic + routeLatency }

        static func forRoute(_ route: AudioRoute, outputLatency: TimeInterval) -> Tail {
            let latency = max(0, outputLatency)
            switch route {
            case .speaker:   return Tail(acoustic: 0.8, routeLatency: latency)
            case .bluetooth: return Tail(acoustic: 0.5, routeLatency: latency)
            case .isolated:  return Tail(acoustic: 0.25, routeLatency: latency)
            }
        }
    }

    /// One sentence that was (or is being) played.
    struct Utterance: Equatable {
        let text: String
        let startedAt: Date
        /// When the sentence's audio ends if it plays out (word positions).
        var plannedEnd: Date
        /// When its audio actually stops being heard (cut on barge-in).
        var lastAudioAt: Date
    }

    /// How long played sentences are remembered for echo matching.
    static let memory: TimeInterval = 20

    private(set) var utterances: [Utterance] = []
    private(set) var tail = Tail(acoustic: 0.8, routeLatency: 0)
    /// When the most recently played audio will have finished leaving the speaker.
    private(set) var playbackEndsAt: Date?
    /// True while buffers are queued/playing on the device.
    private(set) var isPlaying = false

    mutating func updateRoute(_ route: AudioRoute, outputLatency: TimeInterval) {
        tail = .forRoute(route, outputLatency: outputLatency)
    }

    /// A buffer for `text` (the sentence it belongs to) was scheduled and will
    /// play for `duration` seconds after any audio already queued.
    mutating func scheduled(text: String, duration: TimeInterval, now: Date = Date()) {
        let start = max(now, playbackEndsAt ?? now)
        let end = start.addingTimeInterval(duration)
        playbackEndsAt = end
        isPlaying = true
        if let last = utterances.last, last.text == text {
            utterances[utterances.count - 1].lastAudioAt = end
            utterances[utterances.count - 1].plannedEnd = end
        } else if !text.isEmpty {
            utterances.append(Utterance(text: text, startedAt: start, plannedEnd: end, lastAudioAt: end))
        }
        prune(now: now)
    }

    /// All scheduled audio has been played back by the device.
    mutating func drained(now: Date = Date()) {
        isPlaying = false
        if let end = playbackEndsAt, end > now { playbackEndsAt = now }
    }

    /// Playback was cut (barge-in / stop): nothing more will come out after now.
    mutating func stopped(now: Date = Date()) {
        isPlaying = false
        playbackEndsAt = now
        for i in utterances.indices where utterances[i].lastAudioAt > now {
            utterances[i].lastAudioAt = now
        }
    }

    /// Whether the AI's own voice can be in the mic at `date`.
    func isAIAudible(at date: Date = Date()) -> Bool {
        if isPlaying { return true }
        guard let end = playbackEndsAt else { return false }
        return date < end.addingTimeInterval(tail.total)
    }

    /// Text of sentences whose audio could have reached the mic within
    /// `window` seconds before `date` (plus the echo tail).
    func recentSpokenText(within window: TimeInterval, at date: Date = Date()) -> [String] {
        let horizon = date.addingTimeInterval(-(window + tail.total))
        return utterances.filter { $0.lastAudioAt >= horizon }.map(\.text)
    }

    /// The AI's words with estimated heard times, for sentences audible at
    /// any point in `[from, to]` (plus echo tail). Words after a cut-off are
    /// dropped — they were never played.
    func spokenWords(from: Date, to: Date) -> [EchoMatcher.SpokenWord] {
        let lower = from.addingTimeInterval(-tail.total)
        return utterances
            .filter { $0.lastAudioAt >= lower && $0.startedAt <= to }
            .flatMap { u in
                EchoMatcher.spokenWords(text: u.text, from: u.startedAt, to: u.plannedEnd)
                    .filter { $0.start <= u.lastAudioAt }
            }
    }

    private mutating func prune(now: Date) {
        let horizon = now.addingTimeInterval(-Self.memory)
        utterances.removeAll { $0.lastAudioAt < horizon }
    }
}

/// Output route reduced to what matters for echo.
enum AudioRoute: Sendable, Equatable, CustomStringConvertible {
    /// Built-in loudspeaker — strongest acoustic coupling to the mic.
    case speaker
    /// Bluetooth / AirPlay / CarPlay — some coupling, extra latency.
    case bluetooth
    /// Earpiece or wired/USB headphones — little or no coupling.
    case isolated

    var description: String {
        switch self {
        case .speaker: return "speaker"
        case .bluetooth: return "bluetooth"
        case .isolated: return "isolated"
        }
    }
}
