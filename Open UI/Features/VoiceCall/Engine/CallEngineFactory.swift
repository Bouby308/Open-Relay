import Foundation

/// Builds the STT / TTS engines for a call from `VoiceCallSettings`.
/// Always returns a usable engine: if the preferred one fails to prepare,
/// it falls back to Apple Speech / the system voice.
@MainActor
enum CallEngineFactory {

    static func makeSTT(settings: VoiceCallSettings, apiClient: APIClient?) async -> CallSTTEngine {
        let preferred: CallSTTEngine?
        switch settings.sttEngine {
        case "server":
            preferred = apiClient.map { ServerCallSTTEngine(apiClient: $0) }
        case "parakeet":
            preferred = MLXCallSTTEngine(variant: .parakeet)
        case "qwen3":
            preferred = MLXCallSTTEngine(variant: .qwen3)
        default:
            preferred = nil
        }
        if let preferred, await preferred.prepare() { return preferred }
        return await makeAppleSTT()
    }

    /// Best available Apple recogniser: the iOS 26 `SpeechAnalyzer` engine
    /// (continuous, word-timed) when the device + language support it, else
    /// the classic `SFSpeechRecognizer` engine.
    static func makeAppleSTT() async -> CallSTTEngine {
        if #available(iOS 26.0, *) {
            let modern = SpeechAnalyzerCallSTTEngine()
            if await modern.prepare() { return modern }
        }
        let apple = AppleCallSTTEngine()
        _ = await apple.prepare()
        return apple
    }

    /// The call speaks with the **Read Aloud** engine and voice
    /// (Settings → Voice → Assistant's Voice), so there's one voice setting.
    /// "Auto" resolves like Read Aloud: on-device model if it's already
    /// loaded, else server, else the system voice.
    static func makeTTS(
        settings: VoiceCallSettings,
        apiClient: APIClient?,
        ttsService: TextToSpeechService
    ) async -> CallTTSEngine {
        let server: () -> CallTTSEngine? = {
            apiClient.map {
                ServerCallTTSEngine(apiClient: $0, voice: ttsService.serverVoiceId, model: ttsService.serverModel)
            }
        }
        let onDevice: (OnDeviceTTSModel) -> CallTTSEngine? = { model in
            ttsService.isKokoroAvailable
                ? MLXCallTTSEngine(service: makeCallTTSService(model, from: ttsService))
                : nil
        }
        let preferred: CallTTSEngine?
        switch ttsService.preferredEngine {
        case .kokoro: preferred = onDevice(.kokoro)
        case .qwen3:  preferred = onDevice(.qwen3)
        case .server: preferred = server()
        case .system: preferred = nil
        case .auto:
            if ttsService.isKokoroAvailable, ttsService.kokoroService.isReady {
                preferred = onDevice(ttsService.kokoroService.config.activeModel)
            } else {
                preferred = server()
            }
        }
        if let preferred, await preferred.prepare() { return preferred }
        return makeSystemTTS()
    }

    /// A dedicated on-device TTS instance for the call. It copies the voice
    /// choices from Read Aloud but never mutates the read-aloud service, and
    /// the app's background unload (which targets the read-aloud instance)
    /// can't pull the model out from under an active call.
    private static func makeCallTTSService(
        _ model: OnDeviceTTSModel,
        from ttsService: TextToSpeechService
    ) -> OnDeviceTTSService {
        // Free the read-aloud copy first so two models aren't resident at once.
        ttsService.unloadKokoroModel()
        let service = OnDeviceTTSService()
        service.config = ttsService.kokoroService.config
        service.config.activeModel = model
        return service
    }

    static func makeSystemTTS() -> CallTTSEngine {
        let voiceId = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier") ?? ""
        let rate = UserDefaults.standard.double(forKey: "ttsSpeechRate")
        return SystemCallTTSEngine(voiceIdentifier: voiceId.isEmpty ? nil : voiceId,
                                   rateMultiplier: rate > 0 ? rate : 1)
    }
}
