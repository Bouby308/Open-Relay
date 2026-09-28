import AVFoundation
import Foundation
import os.log

/// Reads reply sentences aloud on the watch through `WatchAudio`, so echo
/// cancellation can hear what's playing (needed for speak-to-interrupt).
///
/// Voice is chosen in watch Settings: **Apple** (built in, default) or
/// **Server** — the iPhone makes the audio with your server's voice and the
/// watch downloads it sentence by sentence. A sentence whose server audio
/// isn't available falls back to the Apple voice.
@MainActor
final class ReplySpeaker {

    static let shared = ReplySpeaker()

    let logger = Logger(subsystem: "com.openui.watch", category: "ReplySpeaker")
    private let synthesizer = AVSpeechSynthesizer()
    let audio = WatchAudio.shared
    private var queue: [(index: Int, text: String)] = []
    private var worker: Task<Void, Never>?
    var turnId = 0
    private var serverVoice = false
    var generation = 0

    var isSpeaking: Bool { worker != nil || !queue.isEmpty || audio.isPlaying }

    func begin(turnId: Int, serverVoice: Bool) {
        stop()
        self.turnId = turnId
        self.serverVoice = serverVoice
    }

    func enqueue(_ sentences: [String], startIndex: Int) {
        for (offset, text) in sentences.enumerated() { queue.append((startIndex + offset, text)) }
        startWorker()
    }

    func stop() {
        generation &+= 1
        queue.removeAll()
        worker?.cancel()
        worker = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audio.stopPlayback()
    }

    private func startWorker() {
        guard worker == nil else { return }
        let gen = generation
        worker = Task { [weak self] in
            guard let self else { return }
            guard await self.audio.ensureOutput() else {
                self.logger.error("No audio route for reply playback")
                self.queue.removeAll()
                self.worker = nil
                return
            }
            while let item = self.queue.first, gen == self.generation, !Task.isCancelled {
                self.queue.removeFirst()
                var played = false
                if self.serverVoice { played = await self.playServerClip(index: item.index, gen: gen) }
                if !played, gen == self.generation { await self.playSystemVoice(item.text, gen: gen) }
            }
            if gen == self.generation { self.worker = nil }
        }
    }

    /// Apple's built-in voice, rendered to buffers so it plays through the
    /// shared engine (instead of `speak`, which bypasses echo cancellation).
    private func playSystemVoice(_ text: String, gen: Int) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    continuation.finish()
                    return
                }
                continuation.yield(pcm)
            }
        }
        for await buffer in stream {
            guard gen == generation else { return }
            audio.schedule(buffer)
        }
    }
}
