import Foundation
import CoreML

/// Smart Turn v3.2 end-of-turn classifier, Core ML build
/// (`aufklarer/Smart-Turn-v3.2-CoreML`, BSD-2-Clause, from pipecat-ai/smart-turn-v3).
///
/// The Whisper log-mel front-end and waveform normalisation are inside the
/// model, so it takes raw 16 kHz audio. Runs **CPU-only** so it works while
/// the app is backgrounded.
///
/// Model contract (`smart_turn.mlmodelc`):
/// - `audio` [1, 128000] — last 8 s, most recent audio last, zero-padded at the front
/// - output `probability` [1, 1] — turn complete if > 0.5
nonisolated final class CoreMLSmartTurn: @unchecked Sendable {

    static let modelDirectoryName = "smart_turn.mlmodelc"
    static let windowSamples = 128_000

    private let model: MLModel
    private let input: MLMultiArray

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: config)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
    }

    /// End-of-turn probability for the turn audio (16 kHz mono).
    func probability(for audio: [Float]) throws -> Float {
        let dst = input.dataPointer.assumingMemoryBound(to: Float.self)
        let tail = audio.suffix(Self.windowSamples)
        let offset = Self.windowSamples - tail.count
        if offset > 0 { dst.update(repeating: 0, count: offset) }
        tail.withContiguousStorageIfAvailable {
            (dst + offset).update(from: $0.baseAddress!, count: tail.count)
        } ?? {
            for (i, s) in tail.enumerated() { dst[offset + i] = s }
        }()

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: input)
        ])
        let output = try autoreleasepool { try model.prediction(from: provider) }
        guard let prob = CoreMLSileroVAD.array(output, "probability") else {
            throw CoreMLVADError.missingOutput
        }
        return CoreMLSileroVAD.firstFloat(prob)
    }

    /// One dummy prediction so the first real pause isn't slowed by lazy init.
    func warmUp() {
        _ = try? probability(for: [])
    }
}
