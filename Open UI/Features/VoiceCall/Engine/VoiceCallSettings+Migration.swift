import Foundation

// MARK: - Migration

extension VoiceCallSettings {

    /// Runs at most once per install per step.
    /// 1. v1: copies legacy `sttEngine` into `voiceCall.sttEngine`.
    /// 2. Voice unification: calls used to have their own voice engine
    ///    (`voiceCall.ttsEngine`). Calls now use the Read Aloud engine, so a
    ///    user who picked a specific call voice while Read Aloud was on
    ///    System/Auto gets that voice for both — they chose it deliberately.
    static func migrateLegacyKeysIfNeeded() {
        let defaults = UserDefaults.standard

        if !defaults.bool(forKey: Keys.migrationDone) {
            defaults.set(true, forKey: Keys.migrationDone)
            let legacySTT = defaults.string(forKey: "sttEngine") ?? "device"
            let callSTT: String
            switch legacySTT {
            case "server":   callSTT = "server"
            case "qwen3asr": callSTT = "qwen3"
            default:         callSTT = "apple"
            }
            if defaults.string(forKey: Keys.sttEngine) == nil {
                defaults.set(callSTT, forKey: Keys.sttEngine)
            }
        }

        if !defaults.bool(forKey: Keys.voiceUnifiedDone) {
            defaults.set(true, forKey: Keys.voiceUnifiedDone)
            let readAloud = defaults.string(forKey: "ttsEngine") ?? "system"
            let call = defaults.string(forKey: Keys.legacyTTSEngine) ?? "system"
            let readAloudIsDefault = readAloud == "system" || readAloud == "auto"
            if readAloudIsDefault, call != "system" {
                switch call {
                case "kokoro", "marvis":
                    defaults.set("ondevice", forKey: "ttsEngine")
                    defaults.set("kokoro", forKey: "ttsOnDeviceModel")
                case "qwen3":
                    defaults.set("ondevice", forKey: "ttsEngine")
                    defaults.set("qwen3", forKey: "ttsOnDeviceModel")
                case "server":
                    defaults.set("server", forKey: "ttsEngine")
                default:
                    break
                }
            }
            defaults.removeObject(forKey: Keys.legacyTTSEngine)
        }
    }
}
