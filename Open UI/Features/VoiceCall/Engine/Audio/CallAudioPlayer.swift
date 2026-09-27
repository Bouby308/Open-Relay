import Foundation
import AVFoundation
import os.log

#if canImport(MLXAudioCore)
import MLXAudioCore
#endif

/// Plays TTS audio through the shared `CallAudioEngine` player node and keeps
/// the call's `PlaybackTimeline` exact.
///
/// - The player node lives in the same voice-processing engine as the mic
///   tap, so echo cancellation subtracts what's playing.
/// - Every chunk is tagged with the sentence it belongs to, so the timeline
///   knows *what* the AI said and *when* it actually came out.
/// - Completion is reported on `.dataPlayedBack` (audio left the speaker), not
///   `.dataConsumed` (audio handed to the hardware) — otherwise the call would
///   start listening while the last sentence is still audible.
///
/// Sentence ordering is guaranteed: `scheduleBuffer` is a FIFO queue.
@MainActor
final class CallAudioPlayer {

    fileprivate let logger = Logger(subsystem: "com.openui", category: "CallAudioPlayer")
    fileprivate let callEngine: CallAudioEngine
    fileprivate var playerNode: AVAudioPlayerNode { callEngine.playerNode }

    #if canImport(MLXAudioCore)
    fileprivate var outputConverter: PCMStreamConverter?
    /// Playback format `outputConverter` was built for.
    fileprivate var converterFormat: AVAudioFormat?

    fileprivate func makeConverter() -> PCMStreamConverter {
        let fmt = callEngine.playbackFormat
        converterFormat = fmt
        return PCMStreamConverter(outputFormat: fmt)
    }
    #endif

    /// What the AI played and when — read by turn-taking to recognise echo.
    fileprivate(set) var timeline = PlaybackTimeline()
    /// Level of what the AI played and when it leaves the speaker — predicts
    /// how loud the AI's own voice is in the mic (barge-in echo gating).
    var echo = EchoReference()
    /// Current node volume (1 = full, lower while ducked) applied to `echo`.
    fileprivate var appliedVolume: Float = 1
    /// Output-path latency: scheduled audio is heard this long after it plays.
    fileprivate var outputLatency: TimeInterval = 0
    /// Route `echo` is learning for.
    fileprivate var echoRoute: AudioRoute?

    fileprivate var scheduledBuffers = 0
    /// Bumped on stop/rebuild so late completion callbacks are ignored.
    fileprivate var sessionGeneration = 0
    fileprivate var streamFinished = false
    fileprivate(set) var isSpeaking = false
    fileprivate(set) var isDucked = false
    fileprivate var fadeTask: Task<Void, Never>?

    /// Called once all scheduled audio has been played back by the device.
    var onFinished: (() -> Void)?
    /// Called when the first buffer of a session is scheduled.
    var onStarted: (() -> Void)?

    init(engine: CallAudioEngine) {
        self.callEngine = engine
        refreshRoute()
    }

    // MARK: - Session

    /// Prepare the player for a new reply. Cancels anything still playing.
    func beginSession() {
        stopImmediately()
        streamFinished = false
        #if canImport(MLXAudioCore)
        outputConverter = makeConverter()
        #endif
        startNodeIfPossible()
    }

    /// Schedule one chunk of mono float samples belonging to `sentence`.
    /// Every chunk is converted to the engine's playback format — raw TTS
    /// audio is never handed to the player node.
    func scheduleChunk(_ samples: [Float], sampleRate: Double, sentence: String) {
        guard sampleRate > 0, !samples.isEmpty,
              let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                               frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        srcBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let ch = srcBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        }
        #if canImport(MLXAudioCore)
        // Missing (after a stop) or built for an older format (route change).
        if outputConverter == nil || converterFormat != callEngine.playbackFormat {
            outputConverter = makeConverter()
        }
        do {
            for buf in try outputConverter!.push(srcBuffer) { enqueue(buf, sentence: sentence) }
        } catch {
            logger.error("Chunk conversion failed: \(error.localizedDescription, privacy: .public)")
        }
        #else
        enqueue(srcBuffer, sentence: sentence)   // dropped by enqueue unless formats match
        #endif
    }

    /// No more chunks are coming for this reply.
    func finishSession(lastSentence: String) {
        streamFinished = true
        #if canImport(MLXAudioCore)
        if let converter = outputConverter {
            do {
                for buf in try converter.finish() { enqueue(buf, sentence: lastSentence) }
            } catch {
                logger.error("Finish flush failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        checkCompletion()
    }

    /// Stop immediately and discard queued audio (barge-in, cancel, end call).
    func stopImmediately() {
        let wasPlaying = scheduledBuffers > 0 || isSpeaking
        sessionGeneration &+= 1
        cancelFade()
        playerNode.volume = 1
        playerNode.stop()
        playerNode.reset()
        startNodeIfPossible()
        scheduledBuffers = 0
        streamFinished = false
        isSpeaking = false
        #if canImport(MLXAudioCore)
        outputConverter = nil
        #endif
        if wasPlaying {
            let heardUntil = Date().addingTimeInterval(outputLatency)
            timeline.stopped(now: heardUntil)
            echo.stopped(at: heardUntil)
        }
    }

    /// Re-read the output route and its latency (route changes / rebuilds).
    /// The timeline and echo reference are kept on the "heard" clock — output
    /// latency is already added when audio is scheduled — so the timeline tail
    /// only covers acoustic decay. Learned echo coupling is loaded per route.
    func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let route = AudioRoute.current(session)
        outputLatency = max(0, session.outputLatency + session.ioBufferDuration)
        timeline.updateRoute(route, outputLatency: 0)
        if route != echoRoute {
            if let old = echoRoute, echo.learnedSamples > 20 {
                EchoCouplingStore.save(echo.coupling, route: old)
            }
            echoRoute = route
            echo = EchoReference(coupling: EchoCouplingStore.load(route))
        }
    }

    /// Persist what was learned about this route's echo (call end).
    func saveEchoLearning() {
        guard let route = echoRoute, echo.learnedSamples > 20 else { return }
        EchoCouplingStore.save(echo.coupling, route: route)
    }
}

// MARK: - Ducking

extension CallAudioPlayer {

    /// Volume while a possible barge-in is being confirmed: low enough that the
    /// user is clearly heard over the residual echo, but playback keeps its place.
    static let duckedVolume: Float = 0.15

    /// Fade the AI down without stopping playback.
    func duck() {
        guard !isDucked else { return }
        isDucked = true
        fade(to: Self.duckedVolume, over: 0.08)
    }

    /// Fade back to full volume after a rejected barge-in.
    func unduck() {
        guard isDucked else { return }
        isDucked = false
        fade(to: 1, over: 0.25)
    }
}

// MARK: - Scheduling internals

private extension CallAudioPlayer {

    /// `play()` raises an ObjC exception unless the node is attached and the
    /// underlying AVAudioEngine is actually running (our flag can be ahead of
    /// it during interruptions / failed rebuilds).
    func startNodeIfPossible() {
        guard !playerNode.isPlaying, playerNode.engine != nil, callEngine.engine.isRunning else { return }
        playerNode.play()
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, sentence: String) {
        let rate = buffer.format.sampleRate
        guard rate > 0, buffer.frameLength > 0 else { return }
        // scheduleBuffer raises an uncatchable ObjC exception on a format
        // mismatch or a detached / stopped engine. Never let that happen.
        let nodeFormat = playerNode.outputFormat(forBus: 0)
        guard playerNode.engine != nil, callEngine.isRunning, callEngine.engine.isRunning else {
            logger.error("Dropped TTS buffer — audio engine not running")
            return
        }
        guard buffer.format.sampleRate == nodeFormat.sampleRate,
              buffer.format.channelCount == nodeFormat.channelCount,
              buffer.format.commonFormat == nodeFormat.commonFormat else {
            logger.error("Dropped TTS buffer — format \(buffer.format.sampleRate, format: .fixed(precision: 0)) Hz × \(buffer.format.channelCount) ≠ node \(nodeFormat.sampleRate, format: .fixed(precision: 0)) Hz × \(nodeFormat.channelCount)")
            return
        }
        startNodeIfPossible()
        scheduledBuffers += 1
        let duration = Double(buffer.frameLength) / rate
        let now = Date()
        // When this buffer will be heard: after everything already queued,
        // plus the output path latency (not the moment it's scheduled).
        let heardFrom = max(now.addingTimeInterval(outputLatency), timeline.playbackEndsAt ?? .distantPast)
        timeline.scheduled(text: sentence, duration: duration, now: now.addingTimeInterval(outputLatency))
        recordEchoSlices(buffer, from: heardFrom)
        let gen = sessionGeneration
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.bufferPlayed(generation: gen) }
        }
        if !isSpeaking {
            isSpeaking = true
            onStarted?()
        }
    }

    func bufferPlayed(generation gen: Int) {
        // Buffers flushed by stopImmediately() report back late — ignore them.
        guard gen == sessionGeneration else { return }
        scheduledBuffers = max(scheduledBuffers - 1, 0)
        if scheduledBuffers == 0 { timeline.drained() }
        checkCompletion()
    }

    func checkCompletion() {
        guard streamFinished, scheduledBuffers == 0 else { return }
        streamFinished = false
        isSpeaking = false
        timeline.drained()
        onFinished?()
    }

    /// Records the buffer's loudness in ~20 ms slices on the wall clock.
    func recordEchoSlices(_ buffer: AVAudioPCMBuffer, from start: Date) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let rate = buffer.format.sampleRate
        let n = Int(buffer.frameLength)
        let step = max(1, Int(rate * 0.02))
        var i = 0
        while i < n {
            let len = min(step, n - i)
            var sum: Float = 0
            for k in i..<(i + len) { sum += ch[k] * ch[k] }
            let level = (sum / Float(len)).squareRoot() * appliedVolume
            let from = start.addingTimeInterval(Double(i) / rate)
            echo.played(level: level, from: from, to: from.addingTimeInterval(Double(len) / rate))
            i += len
        }
    }

    func fade(to target: Float, over seconds: Double) {
        fadeTask?.cancel()
        let node = playerNode
        let start = node.volume
        // The echo prediction follows the new volume for audio heard from now.
        if appliedVolume > 0 {
            echo.rescale(by: target / appliedVolume, from: Date().addingTimeInterval(outputLatency))
        }
        appliedVolume = target
        let steps = 8
        fadeTask = Task { @MainActor in
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                if Task.isCancelled { return }
                node.volume = start + (target - start) * Float(i) / Float(steps)
            }
        }
    }

    func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        isDucked = false
        appliedVolume = 1
    }
}

// MARK: - Engine rebuild

extension CallAudioPlayer {

    /// The engine was rebuilt (route change): the node was stopped and the
    /// output format may differ. Queued audio is gone, so the reply ends.
    func engineRebuilt() {
        let wasActive = scheduledBuffers > 0 || isSpeaking
        sessionGeneration &+= 1
        scheduledBuffers = 0
        refreshRoute()
        #if canImport(MLXAudioCore)
        outputConverter = makeConverter()
        #endif
        startNodeIfPossible()
        if wasActive {
            timeline.stopped()
            echo.stopped(at: Date())
            streamFinished = true
            checkCompletion()
        }
    }
}

