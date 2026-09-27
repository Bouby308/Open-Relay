import Foundation
import AVFoundation

/// Base for engines that transcribe a whole finished utterance (server, MLX).
/// Buffers 16 kHz mono samples between `beginTurn` and `finishTurn`.
@MainActor
class UtteranceSTTEngine {

    /// Hard cap on buffered audio (60 s) so memory stays bounded.
    static let maxSamples = 16_000 * 60

    private(set) var samples: [Float] = []
    private(set) var isCollecting = false
    var partialTranscript: String { "" }
    var providesLivePartials: Bool { false }

    func beginTurn() {
        samples.removeAll(keepingCapacity: true)
        isCollecting = true
    }

    func appendNative(_ buffer: AVAudioPCMBuffer, at time: Date) {}

    func appendVAD(_ newSamples: [Float]) {
        guard isCollecting else { return }
        samples.append(contentsOf: newSamples)
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    /// Stops collecting and returns the buffered audio.
    func takeSamples() -> [Float] {
        isCollecting = false
        let out = samples
        samples.removeAll()
        return out
    }

    func cancelTurn() {
        isCollecting = false
        samples.removeAll()
    }

    /// Encodes 16 kHz mono float samples as a 16-bit PCM WAV file.
    nonisolated static func wavData(from samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(byteRate); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataSize)
        data.reserveCapacity(44 + dataSize)
        for s in samples {
            let clamped = max(-1, min(1, s))
            var v = Int16(clamped * Float(Int16.max)).littleEndian
            data.append(Data(bytes: &v, count: 2))
        }
        return data
    }
}
