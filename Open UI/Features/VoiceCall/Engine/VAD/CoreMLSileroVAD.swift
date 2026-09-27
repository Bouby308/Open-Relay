import Foundation
import CoreML
import Accelerate

/// Silero VAD v6 (unified STFT + encoder + decoder), converted to Core ML by
/// FluidInference (`FluidInference/silero-vad-coreml`, MIT).
///
/// Runs **CPU-only**: Core ML never touches Metal, so inference keeps working
/// while the app is backgrounded or the phone is locked (iOS aborts apps that
/// submit GPU work from the background).
///
/// Model contract (`silero-vad-unified-v6.0.0.mlmodelc`):
/// - `audio_input` [1, 576] — 64 samples of context (previous chunk tail) + 512 new samples
/// - `hidden_state`, `cell_state` [1, 128] — LSTM state
/// - outputs `vad_output` [1,1,1], `new_hidden_state`, `new_cell_state` [1, 128]
///
/// Not thread-safe; owned by the `VADPipeline` actor.
nonisolated final class CoreMLSileroVAD: @unchecked Sendable {

    static let modelDirectoryName = "silero-vad-unified-v6.0.0.mlmodelc"
    static let chunkSize = 512
    static let contextSize = 64
    private static let stateSize = 128
    private static let inputSize = chunkSize + contextSize

    private let model: MLModel
    private let audioInput: MLMultiArray
    private let hiddenState: MLMultiArray
    private let cellState: MLMultiArray
    private var context = [Float](repeating: 0, count: contextSize)

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: config)
        audioInput = try MLMultiArray(shape: [1, NSNumber(value: Self.inputSize)], dataType: .float32)
        hiddenState = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        cellState = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        reset()
    }

    /// Clears the LSTM state and audio context (start of a new turn).
    func reset() {
        Self.fill(hiddenState, count: Self.stateSize, value: 0)
        Self.fill(cellState, count: Self.stateSize, value: 0)
        for i in context.indices { context[i] = 0 }
    }

    /// Speech probability (0–1) for exactly `chunkSize` 16 kHz samples.
    func probability(for chunk: [Float]) throws -> Float {
        precondition(chunk.count == Self.chunkSize, "Silero expects \(Self.chunkSize) samples")
        let audio = audioInput.dataPointer.assumingMemoryBound(to: Float.self)
        context.withUnsafeBufferPointer { audio.update(from: $0.baseAddress!, count: Self.contextSize) }
        chunk.withUnsafeBufferPointer {
            (audio + Self.contextSize).update(from: $0.baseAddress!, count: Self.chunkSize)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: audioInput),
            "hidden_state": MLFeatureValue(multiArray: hiddenState),
            "cell_state": MLFeatureValue(multiArray: cellState),
        ])
        let output = try autoreleasepool { try model.prediction(from: input) }

        guard let prob = Self.array(output, "vad_output"),
              let newHidden = Self.array(output, "new_hidden_state"),
              let newCell = Self.array(output, "new_cell_state") else {
            throw CoreMLVADError.missingOutput
        }
        Self.copy(newHidden, into: hiddenState, count: Self.stateSize)
        Self.copy(newCell, into: cellState, count: Self.stateSize)
        context = Array(chunk.suffix(Self.contextSize))
        return Self.firstFloat(prob)
    }

    // MARK: - Helpers

    static func array(_ provider: MLFeatureProvider, _ name: String) -> MLMultiArray? {
        if let v = provider.featureValue(for: name)?.multiArrayValue { return v }
        let match = provider.featureNames.first { $0.lowercased().contains(name) }
        return match.flatMap { provider.featureValue(for: $0)?.multiArrayValue }
    }

    static func firstFloat(_ array: MLMultiArray) -> Float {
        switch array.dataType {
        case .float16: return array[0].floatValue
        default: return array.dataPointer.assumingMemoryBound(to: Float.self)[0]
        }
    }

    private static func fill(_ array: MLMultiArray, count: Int, value: Float) {
        var v = value
        vDSP_vfill(&v, array.dataPointer.assumingMemoryBound(to: Float.self), 1, vDSP_Length(count))
    }

    private static func copy(_ source: MLMultiArray, into dest: MLMultiArray, count: Int) {
        let dst = dest.dataPointer.assumingMemoryBound(to: Float.self)
        if source.dataType == .float32 {
            dst.update(from: source.dataPointer.assumingMemoryBound(to: Float.self), count: count)
        } else {
            for i in 0..<count { dst[i] = source[i].floatValue }
        }
    }
}

enum CoreMLVADError: Error, LocalizedError {
    case missingOutput
    var errorDescription: String? { "Core ML voice model returned no output" }
}
