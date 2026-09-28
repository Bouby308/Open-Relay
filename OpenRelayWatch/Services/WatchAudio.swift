import AVFoundation
import Foundation

/// The watch's single audio engine for Talk: mic in + reply audio out.
///
/// In **conversation** mode the mic and the player share one engine with
/// Apple's voice processing (echo cancellation) on, so the mic hears you but
/// not the reply — that's what makes "speak to interrupt" work.
/// **Playback** mode (typed questions) plays replies without the mic.
@MainActor
final class WatchAudio {

    static let shared = WatchAudio()

    enum Mode { case off, playback, conversation }

    private(set) var mode: Mode = .off
    /// Echo cancellation is active (not every route supports it).
    private(set) var echoCancelling = false
    /// When the reply currently playing started (nil = nothing playing).
    var playbackStartedAt: Date?
    var pendingBuffers = 0

    /// Receives mic audio in conversation mode. Thread-safe.
    let mic = MicTap()
    /// Fixed format every scheduled buffer is converted to.
    let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    var generation = 0
    var converters: [String: AVAudioConverter] = [:]
    var idleStop: Task<Void, Never>?

    var isPlaying: Bool { pendingBuffers > 0 }

    var isMuted = false {
        didSet {
            mic.setMuted(isMuted)
            if echoCancelling, let engine { engine.inputNode.isVoiceProcessingInputMuted = isMuted }
        }
    }

    /// Echo cancellation was seen to deliver no audio during this launch, so
    /// Talk uses plain recording until the app restarts or "Try Again".
    /// (Deliberately not saved — a quiet room once must not disable it forever.)
    private static var echoBrokenThisLaunch = false
    var echoAllowed: Bool {
        get { !Self.echoBrokenThisLaunch }
        set { Self.echoBrokenThisLaunch = !newValue }
    }

    /// Settings → "Try Again": re-enable echo cancellation for the next Talk.
    func retryEcho() {
        echoAllowed = true
        if mode == .conversation { stop() }
    }

    /// Starts mic + speaker. Uses echo cancellation unless it's been found
    /// not to work here (`echoAllowed`) or `useEcho` is false.
    private init() {
        // Older builds saved "echo cancellation broken" permanently — clear it.
        UserDefaults.standard.removeObject(forKey: "watch.echoCancellationBroken")
    }

    func startConversation(useEcho: Bool? = nil) throws {
        idleStop?.cancel()
        guard mode != .conversation else { return }
        stop()
        let wantEcho = useEcho ?? echoAllowed
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: wantEcho ? .voiceChat : .default, options: [])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        echoCancelling = wantEcho && (try? input.setVoiceProcessingEnabled(true)) != nil
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "WatchAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable"])
        }
        // Build the output graph first, then tap the input. Changing the
        // graph after the tap is installed can leave the tap without audio.
        try attachPlayer(to: engine)
        let tap = mic
        tap.attach(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in tap.receive(buffer) }
        if !engine.isRunning { try engine.start() }
        mode = .conversation
        if echoCancelling { input.isVoiceProcessingInputMuted = isMuted }
    }

    /// Restarts the mic without echo cancellation (and remembers that).
    func fallBackToPlainMic() throws {
        echoAllowed = false
        stop()
        try startConversation(useEcho: false)
    }

    /// Makes sure replies can play (conversation mode already can).
    func ensureOutput() async -> Bool {
        idleStop?.cancel()
        if mode != .off { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
            guard try await session.activate(options: []) else { return false }
            guard mode == .off else { return true }
            try attachPlayer(to: AVAudioEngine())
            mode = .playback
            return true
        } catch {
            return false
        }
    }

    func stop() {
        idleStop?.cancel()
        stopPlayback()
        if let engine {
            if mode == .conversation { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        engine = nil
        player = nil
        echoCancelling = false
        mic.detach()
        if mode != .off {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        mode = .off
    }

    private func attachPlayer(to engine: AVAudioEngine) throws {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.player = player
    }
}
