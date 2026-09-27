import Foundation
import os.log

/// Runs Silero VAD per-chunk and Smart Turn v3.2 on demand — off the main thread.
///
/// Both models are Core ML, CPU-only (see `VADModelStore`), so this keeps
/// working while the app is backgrounded or the phone is locked — which is
/// what makes barge-in and end-of-turn detection work outside the app.
///
/// A failed chunk is skipped; only repeated failures disable Silero for the
/// rest of the call, and the caller then falls back to the RMS level + silence
/// timer. Smart Turn failing just returns nil ("trust the silence").
///
/// Owns no turn-taking policy — see `TurnDetector` / `BargeInDetector`.
actor VADPipeline {

    static let sampleRate = 16000
    /// Silero's 16 kHz model takes exactly 512-sample chunks (32 ms).
    static let chunkSize = CoreMLSileroVAD.chunkSize
    /// Trailing audio Smart Turn judges end-of-turn on (its window is 8 s).
    static let smartTurnWindowSeconds: Double = 8.0

    private let logger = Logger(subsystem: "com.openui", category: "VADPipeline")

    private let silero: CoreMLSileroVAD?
    private let smartTurn: CoreMLSmartTurn?
    private var sileroFailed = false
    /// Silero errors in a row; a single bad chunk is skipped, only a
    /// persistent failure disables it (and barge-in) for the call.
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 5

    /// Slowest chunk seen in the current reporting window, for diagnostics.
    private var slowestChunkMs: Double = 0
    private var chunksSinceReport = 0

    /// True when Silero is loaded (otherwise the caller uses the RMS fallback).
    nonisolated let hasSilero: Bool
    /// True when Smart Turn is loaded (otherwise silence alone ends turns).
    nonisolated let hasSmartTurn: Bool

    private var pendingSamples: [Float] = []
    private var turnBuffer: [Float] = []
    private var turnBufferCap: Int { Int(Self.smartTurnWindowSeconds * Double(Self.sampleRate)) }

    /// Built on the main actor from the loaded store, then handed to the actor.
    @MainActor
    static func make(store: VADModelStore) -> VADPipeline {
        VADPipeline(silero: store.silero, smartTurn: store.smartTurn)
    }

    private init(silero: CoreMLSileroVAD?, smartTurn: CoreMLSmartTurn?) {
        self.silero = silero
        self.smartTurn = smartTurn
        self.hasSilero = silero != nil
        self.hasSmartTurn = smartTurn != nil
    }

    /// Resets streaming state for a new turn.
    func reset() {
        silero?.reset()
        pendingSamples.removeAll()
        turnBuffer.removeAll()
    }

    /// Starts a fresh Smart Turn window without touching Silero's state
    /// (used when a barge-in hands the turn to a user who is mid-sentence).
    func resetTurnBuffer() {
        turnBuffer.removeAll()
    }

    /// Feed 16 kHz mono samples. Returns one speech probability per full
    /// 512-sample chunk consumed, or nil when Silero is unavailable (never
    /// loaded, or failed repeatedly) — the caller then uses the RMS fallback.
    func process(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return [] }
        turnBuffer.append(contentsOf: samples)
        if turnBuffer.count > turnBufferCap {
            turnBuffer.removeFirst(turnBuffer.count - turnBufferCap)
        }
        guard let silero, !sileroFailed else { return nil }
        pendingSamples.append(contentsOf: samples)

        var probabilities: [Float] = []
        while pendingSamples.count >= Self.chunkSize {
            let chunk = Array(pendingSamples.prefix(Self.chunkSize))
            pendingSamples.removeFirst(Self.chunkSize)
            let start = CFAbsoluteTimeGetCurrent()
            do {
                probabilities.append(try silero.probability(for: chunk))
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                silero.reset()
                pendingSamples.removeAll()
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    logger.error("Silero failed \(self.consecutiveFailures) times in a row — disabling for this call: \(error.localizedDescription, privacy: .public)")
                    sileroFailed = true
                    return nil
                }
                logger.error("Silero chunk failed (\(self.consecutiveFailures)/\(Self.maxConsecutiveFailures)), skipping: \(error.localizedDescription, privacy: .public)")
                break
            }
            recordTiming(ms: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return probabilities
    }

    /// Smart Turn end-of-turn probability (0–1) on the buffered turn audio,
    /// or nil if the model is unavailable or fails.
    func evaluateEndOfTurn() -> Float? {
        guard let smartTurn, !turnBuffer.isEmpty else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let p = try smartTurn.probability(for: turnBuffer)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            logger.info("Smart Turn p=\(p, format: .fixed(precision: 2)) in \(ms) ms")
            return p
        } catch {
            logger.error("Smart Turn failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Logs the slowest Silero chunk roughly every 10 s (~310 chunks).
    private func recordTiming(ms: Double) {
        slowestChunkMs = max(slowestChunkMs, ms)
        chunksSinceReport += 1
        guard chunksSinceReport >= 310 else { return }
        logger.debug("Silero slowest chunk \(self.slowestChunkMs, format: .fixed(precision: 1)) ms over last \(self.chunksSinceReport) chunks")
        slowestChunkMs = 0
        chunksSinceReport = 0
    }
}
