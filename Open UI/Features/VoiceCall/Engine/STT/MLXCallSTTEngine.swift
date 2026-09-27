import Foundation
import os.log

#if canImport(MLXAudioSTT)
import MLXAudioSTT
import MLXAudioCore
import MLX
import HuggingFace
#endif

/// On-device MLX speech recognition (Parakeet TDT or Qwen3 ASR) that
/// transcribes each finished utterance buffered from the shared mic tap.
@MainActor
final class MLXCallSTTEngine: UtteranceSTTEngine, CallSTTEngine {

    enum Variant: String, CaseIterable, Sendable {
        case parakeet
        case qwen3

        var repoId: String {
            switch self {
            case .parakeet: return "mlx-community/parakeet-tdt-0.6b-v3"
            case .qwen3:    return "mlx-community/Qwen3-ASR-0.6B-8bit"
            }
        }
        var modelType: String {
            switch self {
            case .parakeet: return "parakeet"
            case .qwen3:    return "qwen3_asr"
            }
        }
        var displayName: String {
            switch self {
            case .parakeet: return "Parakeet TDT 0.6B v3"
            case .qwen3:    return "Qwen3 ASR 0.6B"
            }
        }
    }

    let variant: Variant
    var displayName: String { variant.displayName }
    private let logger = Logger(subsystem: "com.openui", category: "MLXCallSTT")

    #if canImport(MLXAudioSTT)
    private final class ModelBox: @unchecked Sendable {
        nonisolated(unsafe) let model: any STTGenerationModel
        init(_ m: any STTGenerationModel) { model = m }
    }
    private var box: ModelBox?
    #endif

    init(variant: Variant) {
        self.variant = variant
    }

    func prepare() async -> Bool {
        #if canImport(MLXAudioSTT)
        if box != nil { return true }
        do {
            let cache = HubCache(location: .fixed(directory: StorageManager.modelCacheDirectory))
            let model = try await STT.loadModel(
                modelRepo: variant.repoId,
                modelType: variant.modelType,
                cache: cache
            )
            box = ModelBox(model)
            logger.info("Loaded \(self.variant.displayName, privacy: .public)")
            return true
        } catch {
            logger.error("Model load failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }

    func finishTurn() async -> String {
        let audio = takeSamples()
        guard audio.count > 4_800 else { return "" }
        #if canImport(MLXAudioSTT)
        guard let box else { return "" }
        let text: String = await Task.detached(priority: .userInitiated) {
            let params = STTGenerateParameters(language: nil, chunkDuration: 30)
            // Throws if the app has left the foreground — the view model then
            // swaps in Apple Speech for the rest of the call.
            let output = try? MLXCallLock.run {
                box.model.generate(audio: MLXArray(audio), generationParameters: params)
            }
            Memory.clearCache()
            return output?.text ?? ""
        }.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return ""
        #endif
    }

    func shutdown() {
        cancelTurn()
        #if canImport(MLXAudioSTT)
        box = nil
        Memory.clearCache()
        #endif
    }
}
