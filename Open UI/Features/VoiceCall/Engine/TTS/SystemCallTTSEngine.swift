import Foundation
import AVFoundation

/// Apple system voice rendered to buffers (never plays itself, never
/// touches the audio session).
@MainActor
final class SystemCallTTSEngine: CallTTSEngine {
    let displayName = "System Voice"
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String?
    private let rate: Float

    init(voiceIdentifier: String?, rateMultiplier: Double) {
        self.voiceIdentifier = voiceIdentifier
        let mult = rateMultiplier > 0 ? Float(rateMultiplier) : 1
        self.rate = min(max(mult * AVSpeechUtteranceDefaultSpeechRate,
                            AVSpeechUtteranceMinimumSpeechRate),
                        AVSpeechUtteranceMaximumSpeechRate)
        synthesizer.usesApplicationAudioSession = true
    }

    func prepare() async -> Bool { true }

    func synthesize(_ sentence: String) -> AsyncThrowingStream<CallTTSChunk, Error> {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = rate
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        }
        return AsyncThrowingStream { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    continuation.finish()
                    return
                }
                continuation.yield(CallTTSChunk(
                    samples: pcm.monoFloatSamples(),
                    sampleRate: pcm.format.sampleRate
                ))
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.synthesizer.stopSpeaking(at: .immediate) }
            }
        }
    }

    func shutdown() { synthesizer.stopSpeaking(at: .immediate) }
}
