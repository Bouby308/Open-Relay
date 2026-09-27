import Foundation
import os.log

/// Speaks a reply sentence-by-sentence through the call's `CallAudioPlayer`.
///
/// Sentences are synthesized in order on one worker task and scheduled on
/// the player as soon as audio arrives, so synthesis of sentence N+1
/// overlaps playback of sentence N. `cancel()` bumps a generation counter,
/// so late audio from an interrupted reply is always discarded.
@MainActor
final class CallSpeechPipeline {

    private let logger = Logger(subsystem: "com.openui", category: "CallSpeech")
    private let player: CallAudioPlayer
    private var engine: CallTTSEngine

    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var inputFinished = false
    private var sessionStarted = false
    private var currentSentence: String?
    private var currentSentenceScheduled = false
    /// Last sentence whose audio was scheduled (tags the final converter flush).
    private var lastScheduledSentence = ""
    /// Fires once when the first audio of a reply starts playing.
    var onStarted: (() -> Void)?
    /// Fires once when every queued sentence has finished playing.
    var onFinished: (() -> Void)?

    private(set) var isActive = false

    init(player: CallAudioPlayer, engine: CallTTSEngine) {
        self.player = player
        self.engine = engine
        player.onStarted = { [weak self] in self?.onStarted?() }
        player.onFinished = { [weak self] in self?.playerFinished() }
    }

    /// Swap engines (fallback to the system voice after an error, or when the
    /// app leaves the foreground). A sentence being synthesized on the old
    /// engine is cancelled right away (so no more GPU work is submitted) and
    /// re-queued on the new engine if none of its audio was scheduled yet.
    func replaceEngine(_ newEngine: CallTTSEngine) {
        let old = engine
        engine = newEngine
        if worker != nil {
            generation &+= 1
            worker?.cancel()
            worker = nil
            if let sentence = currentSentence, !currentSentenceScheduled {
                queue.insert(sentence, at: 0)
            }
            currentSentence = nil
            if isActive {
                startWorkerIfNeeded()
                if queue.isEmpty { completeIfDrained() }
            }
        }
        old.shutdown()
    }

    /// Start a new reply. Cancels anything still playing.
    func begin() {
        cancel()
        isActive = true
        inputFinished = false
        sessionStarted = false
        lastScheduledSentence = ""
    }

    func enqueue(_ sentences: [String]) {
        guard isActive, !sentences.isEmpty else { return }
        queue.append(contentsOf: sentences)
        startWorkerIfNeeded()
    }

    /// No more text is coming for this reply.
    func finishInput() {
        guard isActive else { return }
        inputFinished = true
        if worker == nil { completeIfDrained() }
    }

    /// Stop immediately (barge-in, end call). Never fires `onFinished`.
    func cancel() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        queue.removeAll()
        currentSentence = nil
        isActive = false
        inputFinished = false
        sessionStarted = false
        player.stopImmediately()
    }

    func shutdown() {
        cancel()
        engine.shutdown()
    }

    // MARK: - Private

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let gen = generation
        worker = Task { [weak self] in
            await self?.runWorker(generation: gen)
        }
    }

    private func runWorker(generation gen: Int) async {
        while gen == generation, !queue.isEmpty {
            let sentence = queue.removeFirst()
            currentSentence = sentence
            currentSentenceScheduled = false
            do {
                for try await chunk in engine.synthesize(sentence) {
                    guard gen == generation, !Task.isCancelled else { return }
                    guard !chunk.samples.isEmpty else { continue }
                    if !sessionStarted {
                        player.beginSession()
                        sessionStarted = true
                    }
                    player.scheduleChunk(chunk.samples, sampleRate: chunk.sampleRate, sentence: sentence)
                    currentSentenceScheduled = true
                    lastScheduledSentence = sentence
                }
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                logger.error("TTS failed: \(error.localizedDescription, privacy: .public) — skipping sentence")
            }
        }
        guard gen == generation else { return }
        currentSentence = nil
        worker = nil
        completeIfDrained()
    }

    /// Called when the worker is idle: finish the player session if done.
    private func completeIfDrained() {
        guard isActive, inputFinished, queue.isEmpty, worker == nil else { return }
        if sessionStarted {
            player.finishSession(lastSentence: lastScheduledSentence)   // → playerFinished() when audio drains
        } else {
            isActive = false
            onFinished?()            // nothing was ever spoken
        }
    }

    private func playerFinished() {
        // The player drains between sentences if synthesis is slower than
        // playback — only treat it as the end when no more text is pending.
        guard isActive, inputFinished, queue.isEmpty, worker == nil else { return }
        isActive = false
        sessionStarted = false
        onFinished?()
    }
}
