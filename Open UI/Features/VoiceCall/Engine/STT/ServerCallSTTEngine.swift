import Foundation
import os.log

/// Uploads each finished utterance to the Open WebUI transcription endpoint.
@MainActor
final class ServerCallSTTEngine: UtteranceSTTEngine, CallSTTEngine {

    let displayName = "Server"
    private let logger = Logger(subsystem: "com.openui", category: "ServerCallSTT")
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func prepare() async -> Bool { true }

    func finishTurn() async -> String {
        let audio = takeSamples()
        // Ignore < 0.3 s of audio — nothing useful to transcribe.
        guard audio.count > 4_800 else { return "" }
        let wav = Self.wavData(from: audio)
        do {
            let result = try await apiClient.transcribeSpeech(audioData: wav, fileName: "call.wav")
            let text = (result["text"] as? String) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Server transcription failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    func shutdown() { cancelTurn() }
}
