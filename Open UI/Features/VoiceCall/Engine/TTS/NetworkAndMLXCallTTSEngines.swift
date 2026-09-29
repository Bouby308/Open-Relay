import Foundation
import AVFoundation

/// Open WebUI `/audio/speech` voice, decoded to float samples.
@MainActor
final class ServerCallTTSEngine: CallTTSEngine {
    let displayName = "Server Voice"
    private let apiClient: APIClient
    private var voice: String?
    private let model: String?

    init(apiClient: APIClient, voice: String?, model: String?) {
        self.apiClient = apiClient
        self.voice = voice
        self.model = model
    }

    func prepare() async -> Bool {
        if voice == nil {
            voice = (try? await apiClient.getBackendConfig())?.audio?.tts?.voice
        }
        return true
    }

    func synthesize(_ sentence: String) -> AsyncThrowingStream<CallTTSChunk, Error> {
        let api = apiClient, voice = voice, model = model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (data, contentType) = try await api.generateSpeech(text: sentence, voice: voice, model: model)
                    try Task.checkCancellation()
                    let chunk = try await Task.detached {
                        try ServerCallTTSEngine.decode(data, contentType: contentType)
                    }.value
                    continuation.yield(chunk)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func shutdown() {}

    /// Decodes any AVAudioFile-readable blob to mono floats. The temp-file
    /// extension follows the response Content-Type (with a magic-byte check),
    /// because AVAudioFile uses it to pick the parser.
    nonisolated static func decode(_ data: Data, contentType: String) throws -> CallTTSChunk {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + fileExtension(for: data, contentType: contentType))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CallTTSError.decodeFailed
        }
        try file.read(into: buf)
        return CallTTSChunk(samples: buf.monoFloatSamples(), sampleRate: format.sampleRate)
    }

    nonisolated static func fileExtension(for data: Data, contentType: String) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x41, 0x56, 0x45] {
            return "wav"
        }
        if bytes.count >= 4, bytes[0...3] == [0x4F, 0x67, 0x67, 0x53] { return "ogg" }
        if bytes.count >= 4, bytes[0...3] == [0x66, 0x4C, 0x61, 0x43] { return "flac" }
        if bytes.count >= 8, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return "m4a" }
        let type = contentType.lowercased()
        if type.contains("wav") { return "wav" }
        if type.contains("aac") { return "aac" }
        if type.contains("mp4") || type.contains("m4a") { return "m4a" }
        if type.contains("flac") { return "flac" }
        if type.contains("ogg") || type.contains("opus") { return "ogg" }
        return "mp3"
    }
}

/// Server voice with the system voice as a per-sentence safety net: a
/// sentence the server can't deliver (network drop, timeout) is spoken by the
/// system voice instead of being skipped. Used while the app is backgrounded
/// in place of an on-device voice.
@MainActor
final class FallbackCallTTSEngine: CallTTSEngine {
    private let primary: CallTTSEngine
    private let backup: CallTTSEngine
    var displayName: String { primary.displayName }

    init(primary: CallTTSEngine, backup: CallTTSEngine) {
        self.primary = primary
        self.backup = backup
    }

    func prepare() async -> Bool {
        let ok = await primary.prepare()
        _ = await backup.prepare()
        return ok
    }

    func synthesize(_ sentence: String) -> AsyncThrowingStream<CallTTSChunk, Error> {
        let primary = primary, backup = backup
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var produced = false
                do {
                    for try await chunk in primary.synthesize(sentence) {
                        produced = true
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                    return
                } catch {
                    // Audio already played for this sentence: don't repeat it.
                    if produced || Task.isCancelled { continuation.finish(); return }
                }
                do {
                    for try await chunk in backup.synthesize(sentence) { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func shutdown() {
        primary.shutdown()
        backup.shutdown()
    }
}

/// On-device Kokoro / Qwen3 via the shared `OnDeviceTTSService` model.
@MainActor
final class MLXCallTTSEngine: CallTTSEngine {
    private let service: OnDeviceTTSService
    var displayName: String { service.config.activeModel.displayName }
    var model: OnDeviceTTSModel { service.config.activeModel }

    init(service: OnDeviceTTSService) {
        self.service = service
    }

    /// Voice / speed / language changes for the loaded model — applied to
    /// the next sentence without reloading the model.
    func updateVoice(from config: OnDeviceTTSConfig) {
        guard config.activeModel == service.config.activeModel else { return }
        service.config = config
    }

    func prepare() async -> Bool {
        do {
            try await service.loadModel()
            return service.callOutputSampleRate != nil
        } catch {
            return false
        }
    }

    func synthesize(_ sentence: String) -> AsyncThrowingStream<CallTTSChunk, Error> {
        let service = service
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    // In the background the GPU is off-limits. Wait instead of
                    // failing: the call swaps this engine out (cancelling the
                    // wait and re-queueing the sentence on the new engine), or
                    // the app returns to the foreground and it simply continues.
                    while !MLXCallLock.gpuAllowed {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    let rate = service.callOutputSampleRate ?? 24_000
                    for try await samples in service.synthesizeForCall(sentence) {
                        continuation.yield(CallTTSChunk(samples: samples, sampleRate: rate))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Releases the call's own model instance (never the read-aloud one).
    func shutdown() {
        service.unloadModel()
    }
}