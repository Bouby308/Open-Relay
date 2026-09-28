import Foundation
import AVFoundation
import Speech

/// Live words while the user is still speaking on the watch. Each incoming
/// audio chunk is fed to an Apple Speech request; the watch polls
/// `liveTranscript` to show the words. Best-effort — if speech recognition
/// isn't available (permission, background limits) the watch simply shows
/// the final transcript later.
@MainActor
final class WatchLiveTranscriber {

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var turnId: Int?
    private(set) var text = ""
    private var nextSeq = 0
    private var pending: [Int: Data] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: WatchProtocol.audioSampleRate, channels: 1)!

    /// Only runs when the user already allowed speech recognition.
    private var allowed: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    func feed(turn: Int, seq: Int, pcm: Data) {
        guard allowed else { return }
        if turnId != turn { start(turn) }
        guard request != nil else { return }
        pending[seq] = pcm
        // Feed strictly in order; retried chunks are ignored.
        while let next = pending.removeValue(forKey: nextSeq) {
            append(next)
            nextSeq += 1
        }
    }

    func partial(for turn: Int) -> String? {
        turnId == turn && !text.isEmpty ? text : nil
    }

    func finish(turn: Int) {
        guard turnId == turn else { return }
        stop()
    }

    private func start(_ turn: Int) {
        stop()
        turnId = turn
        let saved = UserDefaults.standard.string(forKey: "sttLocale") ?? ""
        let recognizer = saved.isEmpty ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: Locale(identifier: saved))
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.recognizer = recognizer
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let words = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in
                guard let self, self.turnId == turn else { return }
                self.text = words
            }
        }
    }

    private func append(_ pcm: Data) {
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                channel[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32_768
            }
        }
        request?.append(buffer)
    }

    private func stop() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        turnId = nil
        text = ""
        nextSeq = 0
        pending.removeAll()
    }
}
