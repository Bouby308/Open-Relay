import Foundation
import AVFoundation
import os.log

// MARK: - Playback

extension WatchPhoneSpeaker {

    func schedule(_ chunk: CallTTSChunk) {
        guard !chunk.samples.isEmpty,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        for (i, s) in chunk.samples.enumerated() { channel[i] = s }
        guard prepareEngine(for: fmt) else { return }
        pendingBuffers += 1
        let id = turnId
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(turn: id) }
        }
        if !player.isPlaying { player.play() }
    }

    private func prepareEngine(for fmt: AVAudioFormat) -> Bool {
        if format != fmt {
            if pendingBuffers > 0 { player.stop(); pendingBuffers = 0 }
            if engine.isRunning { engine.stop() }
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            format = fmt
        }
        guard !engine.isRunning else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            logger.error("Watch reply audio failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func bufferPlayed(turn id: Int?) {
        guard id == turnId else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if pendingBuffers == 0 && worker == nil && inputDone { finish() }
    }

    func finish() {
        stopPlayback()
        turnId = nil
    }

    func stopPlayback() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
        pendingBuffers = 0
        player.stop()
        guard engine.isRunning else { return }
        engine.stop()
        // Restore the app's launch-time baseline category.
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
    }
}
