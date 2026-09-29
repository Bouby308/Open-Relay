import Foundation

/// Which voice (TTS) and listening (STT) engines a call *should* be using
/// right now — derived from the user's settings plus whether the app is in
/// the foreground.
///
/// On-device (MLX) models run on the GPU, which iOS forbids in the
/// background, so while backgrounded:
/// - an on-device **voice** falls back to the **server voice** (with the
///   system voice as a per-sentence safety net), or the system voice when
///   no server is configured;
/// - on-device **listening** falls back to the **server**, or Apple Speech.
///
/// Each choice has a `signature` covering everything that affects the sound
/// (engine, model, voice, speed, language), so the call only rebuilds an
/// engine when something the user would actually hear has changed.
@MainActor
struct CallEngineSelection: Equatable {

    enum Voice: Equatable {
        case onDevice(OnDeviceTTSModel)
        case server
        /// Server voice used as a background stand-in for on-device.
        case serverFallback
        case system
    }

    enum Listening: Equatable {
        case apple
        case server
        case onDevice(MLXCallSTTEngine.Variant)
    }

    let voice: Voice
    let voiceSignature: String
    let listening: Listening
    let listeningSignature: String

    /// Resolves the wanted engines from the current settings.
    /// - Parameter onDeviceLoaded: the call already runs this on-device model
    ///   (Auto mode treats it as ready — the call's own copy is loaded even
    ///   though the read-aloud copy was unloaded to save memory).
    static func resolve(
        settings: VoiceCallSettings,
        ttsService: TextToSpeechService,
        hasServer: Bool,
        inForeground: Bool,
        onDeviceLoaded: OnDeviceTTSModel? = nil
    ) -> CallEngineSelection {
        let defaults = UserDefaults.standard

        // MARK: Voice
        let wantedVoice: Voice
        switch ttsService.preferredEngine {
        case .kokoro: wantedVoice = ttsService.isKokoroAvailable ? .onDevice(.kokoro) : (hasServer ? .server : .system)
        case .qwen3:  wantedVoice = ttsService.isKokoroAvailable ? .onDevice(.qwen3) : (hasServer ? .server : .system)
        case .server: wantedVoice = hasServer ? .server : .system
        case .system: wantedVoice = .system
        case .auto:
            let active = ttsService.kokoroService.config.activeModel
            if ttsService.isKokoroAvailable, ttsService.kokoroService.isReady || onDeviceLoaded == active {
                wantedVoice = .onDevice(active)
            } else {
                wantedVoice = hasServer ? .server : .system
            }
        }
        var voice = wantedVoice
        if case .onDevice = wantedVoice, !inForeground {
            voice = hasServer ? .serverFallback : .system
        }

        let config = ttsService.kokoroService.config
        let voiceSignature: String
        switch voice {
        case .onDevice(.kokoro):
            voiceSignature = "kokoro|\(config.kokoroVoice)|\(config.speed)"
        case .onDevice(.qwen3):
            voiceSignature = "qwen3|\(config.qwen3Voice)|\(config.qwen3Language)|\(config.qwen3Speed)"
        case .server:
            voiceSignature = "server|\(ttsService.serverVoiceId ?? "")|\(ttsService.serverModel ?? "")"
        case .serverFallback:
            // The system voice is this engine's per-sentence backup.
            voiceSignature = "server|\(ttsService.serverVoiceId ?? "")|\(ttsService.serverModel ?? "")|"
                + systemSignature(defaults)
        case .system:
            voiceSignature = systemSignature(defaults)
        }

        // MARK: Listening
        let wantedListening: Listening
        switch settings.sttEngine {
        case "server":   wantedListening = hasServer ? .server : .apple
        case "parakeet": wantedListening = .onDevice(.parakeet)
        case "qwen3":    wantedListening = .onDevice(.qwen3)
        default:         wantedListening = .apple
        }
        var listening = wantedListening
        if case .onDevice = wantedListening, !inForeground {
            listening = hasServer ? .server : .apple
        }
        let locale = defaults.string(forKey: "sttLocale") ?? ""
        let listeningSignature: String
        switch listening {
        case .apple:             listeningSignature = "apple|\(locale)"
        case .server:            listeningSignature = "server"
        case .onDevice(let v):   listeningSignature = "mlx|\(v.rawValue)"
        }

        return CallEngineSelection(
            voice: voice, voiceSignature: voiceSignature,
            listening: listening, listeningSignature: listeningSignature
        )
    }

    private static func systemSignature(_ defaults: UserDefaults) -> String {
        "system|\(defaults.string(forKey: "ttsVoiceIdentifier") ?? "")|\(defaults.double(forKey: "ttsSpeechRate"))"
    }
}
