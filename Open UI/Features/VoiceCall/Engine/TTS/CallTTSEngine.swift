import Foundation
import AVFoundation

/// One chunk of synthesized mono float audio.
struct CallTTSChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

/// A text-to-speech engine used during a voice call.
///
/// Engines only produce audio samples. Playback always happens through the
/// call's `CallAudioPlayer`, so echo cancellation hears the output and the
/// audio session is never reconfigured mid-call.
@MainActor
protocol CallTTSEngine: AnyObject {
    var displayName: String { get }
    /// Load models / fetch config. Returns false if unusable.
    func prepare() async -> Bool
    /// Synthesize one sentence into audio chunks.
    func synthesize(_ sentence: String) -> AsyncThrowingStream<CallTTSChunk, Error>
    /// Release resources when the call ends.
    func shutdown()
}

enum CallTTSError: LocalizedError {
    case unavailable
    case decodeFailed
    var errorDescription: String? {
        switch self {
        case .unavailable:  return "Voice engine unavailable."
        case .decodeFailed: return "Could not decode speech audio."
        }
    }
}

extension AVAudioPCMBuffer {
    /// First channel as Float samples, converting from Int16 if needed.
    nonisolated func monoFloatSamples() -> [Float] {
        let n = Int(frameLength)
        if let ch = floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: n))
        }
        if let ch = int16ChannelData?[0] {
            return (0..<n).map { Float(ch[$0]) / Float(Int16.max) }
        }
        return []
    }
}
