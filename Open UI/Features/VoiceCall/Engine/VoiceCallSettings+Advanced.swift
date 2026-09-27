import Foundation

// MARK: - Advanced (continued)

extension VoiceCallSettings {

    static let sustainRange: ClosedRange<Double> = 0.6...2.0

    /// Speech (seconds) over the AI that interrupts even before any words
    /// are recognised. nil = sensitivity preset.
    var interruptAfter: Double? {
        get {
            _ = revision
            guard defaults.object(forKey: Keys.interruptAfter) != nil else { return nil }
            return defaults.double(forKey: Keys.interruptAfter).clamped(to: Self.sustainRange)
        }
        set {
            if let v = newValue { defaults.set(v.clamped(to: Self.sustainRange), forKey: Keys.interruptAfter) }
            else { defaults.removeObject(forKey: Keys.interruptAfter) }
            revision += 1
        }
    }

    var echoProtection: EchoProtection {
        get { _ = revision; return EchoProtection(rawValue: defaults.string(forKey: Keys.echoProtection) ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Keys.echoProtection); revision += 1 }
    }

    /// Shows a live turn-taking readout on the call screen.
    var diagnosticsEnabled: Bool {
        get { bool(Keys.diagnostics, default: false) }
        set { set(newValue, Keys.diagnostics) }
    }

    /// Effective pause range for the call (preset or custom).
    var pauseRange: (min: TimeInterval, max: TimeInterval) {
        guard customPauseEnabled else { return (turnPace.minPause, turnPace.maxPause) }
        let lo = customMinPause
        return (lo, max(customMaxPause, lo + 0.3))
    }

    /// True when any Advanced option differs from its default.
    var hasAdvancedChanges: Bool {
        !vadEnabled || !smartTurnEnabled || customPauseEnabled || interruptAfter != nil
            || echoProtection != .normal || diagnosticsEnabled
    }

    /// Restores every Advanced option to its default.
    func resetAdvanced() {
        [Keys.vadEnabled, Keys.smartTurnEnabled, Keys.customPauseEnabled, Keys.customMinPause,
         Keys.customMaxPause, Keys.interruptAfter, Keys.echoProtection, Keys.diagnostics]
            .forEach(defaults.removeObject(forKey:))
        revision += 1
    }

    /// Forgets the echo levels learned per audio route.
    func resetLearnedEcho() {
        for route in [AudioRoute.speaker, .bluetooth, .isolated] {
            defaults.removeObject(forKey: "voiceCall.echoCoupling.\(route)")
        }
        revision += 1
    }

    // MARK: Storage helpers

    func bool(_ key: String, default value: Bool) -> Bool {
        _ = revision
        guard defaults.object(forKey: key) != nil else { return value }
        return defaults.bool(forKey: key)
    }

    func double(_ key: String, default value: Double, in range: ClosedRange<Double>) -> Double {
        _ = revision
        guard defaults.object(forKey: key) != nil else { return value }
        return defaults.double(forKey: key).clamped(to: range)
    }

    func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        revision += 1
    }

    // MARK: Keys

    enum Keys {
        static let sttEngine          = "voiceCall.sttEngine"
        /// Legacy: calls now use the Read Aloud engine (`ttsEngine`).
        static let legacyTTSEngine    = "voiceCall.ttsEngine"
        static let vadSensitivity     = "voiceCall.vadSensitivity"
        static let turnPace           = "voiceCall.turnPace"
        static let bargeInEnabled     = "voiceCall.bargeIn"
        static let defaultSpeakerOn   = "voiceCall.speakerDefault"
        static let vadEnabled         = "voiceCall.vadEnabled"
        static let smartTurnEnabled   = "voiceCall.smartTurnEnabled"
        static let customPauseEnabled = "voiceCall.customPause"
        static let customMinPause     = "voiceCall.customMinPause"
        static let customMaxPause     = "voiceCall.customMaxPause"
        static let interruptAfter     = "voiceCall.interruptAfter"
        static let echoProtection     = "voiceCall.echoProtection"
        static let diagnostics        = "voiceCall.diagnostics"
        static let migrationDone      = "voiceCall.migrationV1Done"
        static let voiceUnifiedDone   = "voiceCall.voiceUnifiedV1Done"
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
