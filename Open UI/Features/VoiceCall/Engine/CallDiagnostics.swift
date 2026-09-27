import Foundation

/// Live turn-taking readout shown on the call screen when Diagnostics is on
/// (Settings → Voice → Voice Calls → Advanced). Lets users see why the call
/// decided what it did, and tune accordingly.
struct CallDiagnostics: Equatable, Sendable {
    /// Latest Silero speech probability (nil when voice detection is off).
    var speechProbability: Float?
    /// Current pause while the user is talking (seconds).
    var pause: TimeInterval = 0
    /// Pause needed to end the turn right now (seconds).
    var requiredPause: TimeInterval = 0
    /// Latest Smart Turn verdict (nil = not evaluated / disabled).
    var smartTurn: Float?
    /// Mic level ÷ expected AI echo while the AI talks (nil otherwise).
    var echoRatio: Float?
    /// Last turn-taking decision, human readable.
    var lastEvent: String = "Listening"
    /// Engines / modes in effect for this call.
    var mode: String = ""

    var summary: String {
        var parts: [String] = []
        if let p = speechProbability { parts.append(String(format: "voice %.0f%%", p * 100)) }
        if pause > 0 { parts.append(String(format: "pause %.1f/%.1fs", pause, requiredPause)) }
        if let s = smartTurn { parts.append(String(format: "done %.0f%%", s * 100)) }
        if let e = echoRatio { parts.append(e.isFinite ? String(format: "×echo %.1f", e) : "×echo –") }
        return parts.joined(separator: " · ")
    }
}
