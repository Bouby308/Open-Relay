import Foundation
import AVFoundation

/// A recognised word with its position on the call's wall clock.
struct TimedWord: Equatable, Sendable {
    let text: String
    let start: Date
    let end: Date
    /// False while the recogniser may still revise it (volatile result).
    let isFinal: Bool
}

/// A speech-to-text engine used during a voice call.
///
/// Engines never own the microphone or the audio session. They are fed
/// audio from the shared `CallAudioEngine` tap by the orchestrator:
/// - `appendNative(_:at:)` receives native-rate mic buffers (streaming engines).
/// - `appendVAD(_:)` receives 16 kHz mono samples (utterance engines).
/// `finishTurn()` returns the final transcript for the current turn.
///
/// **Continuous engines** (`isContinuous`) transcribe every frame for the
/// whole call — including while the AI speaks — and expose word timings.
/// A turn is then just a time window: `beginTurn(from:)` can start it in the
/// past, so the words that triggered a barge-in are never lost.
@MainActor
protocol CallSTTEngine: AnyObject {
    /// Human-readable name for logs / settings.
    var displayName: String { get }
    /// Live partial transcript of the current turn ("" if unsupported).
    var partialTranscript: String { get }
    /// True when `partialTranscript` updates while audio is still arriving.
    var providesLivePartials: Bool { get }
    /// True when the engine hears every frame for the whole call and can
    /// answer `words(from:)` — enables timing-based echo rejection.
    var isContinuous: Bool { get }

    /// Prepare (load models, request permission). Returns false if unusable.
    func prepare() async -> Bool
    /// Begin a new turn. Discards any previous turn state.
    func beginTurn()
    /// Begin a turn whose audio started at `date` (continuous engines only;
    /// others treat it as `beginTurn()`).
    func beginTurn(from date: Date)
    /// Native-rate mic buffer captured at `time`.
    func appendNative(_ buffer: AVAudioPCMBuffer, at time: Date)
    /// 16 kHz mono samples from the shared engine tap.
    func appendVAD(_ samples: [Float])
    /// Words heard since `date` (continuous engines; [] otherwise).
    func words(from date: Date) -> [TimedWord]
    /// End the turn and return the final transcript ("" if nothing heard).
    func finishTurn() async -> String
    /// Abort the current turn without transcribing.
    func cancelTurn()
    /// Release models / recognizers when the call ends.
    func shutdown()
}

extension CallSTTEngine {
    var isContinuous: Bool { false }
    func beginTurn(from date: Date) { beginTurn() }
    func words(from date: Date) -> [TimedWord] { [] }
}
