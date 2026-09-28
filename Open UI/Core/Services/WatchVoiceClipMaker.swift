import Foundation
import AVFoundation
import os.log

/// Makes server-voice audio clips for the Apple Watch, one per reply
/// sentence. Each clip is AAC (m4a, 24 kHz mono) so it stays small enough
/// for WatchConnectivity (~4 KB per second of speech); longer clips are split
/// into parts the watch fetches one by one.
@MainActor
final class WatchVoiceClipMaker {

    private let logger = Logger(subsystem: "com.openui", category: "WatchVoice")
    private var engine: ServerCallTTSEngine?
    private var clips: [Int: [Int: [Data]]] = [:]     // turn → sentence → parts
    private var failed: [Int: Set<Int>] = [:]
    private var queue: [(turn: Int, index: Int, text: String)] = []
    private var worker: Task<Void, Never>?

    enum ClipState {
        case pending
        case ready(parts: [Data])
        case unavailable
    }

    /// Queues sentences `startIndex…` of `turn` for synthesis.
    func enqueue(_ sentences: [String], turn: Int, startIndex: Int) {
        for (offset, text) in sentences.enumerated() {
            queue.append((turn, startIndex + offset, text))
        }
        startWorker()
    }

    func clip(turn: Int, index: Int) -> ClipState {
        if let parts = clips[turn]?[index] { return .ready(parts: parts) }
        if failed[turn]?.contains(index) == true { return .unavailable }
        return .pending
    }

    /// Stops making audio for `turn` and frees what was made.
    func discard(turn: Int) {
        clips[turn] = nil
        failed[turn] = nil
        queue.removeAll { $0.turn == turn }
    }

    /// Keeps memory bounded — only the given turns are kept.
    func prune(keeping turns: Set<Int>) {
        clips = clips.filter { turns.contains($0.key) }
        failed = failed.filter { turns.contains($0.key) }
        queue.removeAll { !turns.contains($0.turn) }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let job = self.queue.first, !Task.isCancelled {
                self.queue.removeFirst()
                if let parts = await self.make(job.text) {
                    self.clips[job.turn, default: [:]][job.index] = parts
                } else {
                    self.failed[job.turn, default: []].insert(job.index)
                }
            }
            self.worker = nil
        }
    }

    private func make(_ sentence: String) async -> [Data]? {
        guard let tts = await serverEngine() else { return nil }
        var samples: [Float] = []
        var rate: Double = 24_000
        do {
            for try await chunk in tts.synthesize(sentence) {
                samples.append(contentsOf: chunk.samples)
                rate = chunk.sampleRate
            }
        } catch {
            logger.error("⌚️ Server voice failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard !samples.isEmpty else { return nil }
        let encoded = await Task.detached { WatchAudioEncoder.encodeAAC(samples, sampleRate: rate) }.value
        guard let encoded else { return nil }
        return WatchAudioEncoder.split(encoded)
    }

    private func serverEngine() async -> ServerCallTTSEngine? {
        if let engine { return engine }
        guard let deps = WatchRelayService.shared.dependencies, let api = deps.apiClient else { return nil }
        let tts = deps.textToSpeechService
        let made = ServerCallTTSEngine(apiClient: api, voice: tts.serverVoiceId, model: tts.serverModel)
        guard await made.prepare() else { return nil }
        engine = made
        return made
    }
}
