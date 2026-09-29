import Foundation
import os.log

// MARK: - Barge-in decisions

extension CallOrchestrator {

    func handleBargeIn(_ event: BargeInDetector.Event, frame: MicFrame,
                       observation o: BargeInDetector.Observation) {
        let ratio = o.ratioAboveEcho.isFinite ? String(format: "%.1f", o.ratioAboveEcho) : "inf"
        let words = o.novelWords.map(String.init) ?? "n/a"
        switch event {
        case .duck:
            // The candidate starts where its above-echo speech started.
            let start = frame.capturedAt.addingTimeInterval(-(bargeIn.config.duckMs + 64) / 1000)
            candidateStartedAt = start
            logger.info("[call] barge-in candidate p=\(o.probability, format: .fixed(precision: 2)) xecho=\(ratio, privacy: .public) coupling=\(self.player.echo.coupling, format: .fixed(precision: 3)) stt=\(self.stt.displayName, privacy: .public)")
            player.duck()
            noteDiagnostic("Maybe interrupting…")
            if stt.isContinuous {
                stt.beginTurn(from: start)
            } else {
                stt.beginTurn()
                for f in recentFrames.frames(since: start) {
                    stt.appendNative(f.native, at: f.capturedAt)
                    if !f.vadSamples.isEmpty { stt.appendVAD(f.vadSamples) }
                }
            }
        case .resume:
            logger.info("[call] barge-in rejected: \(self.bargeIn.lastReason?.rawValue ?? "?", privacy: .public) (speech \(Int(self.bargeIn.lastSpeechMs)) ms, novel words \(words, privacy: .public), heard \"\(self.stt.partialTranscript, privacy: .private)\")")
            candidateStartedAt = nil
            if !stt.isContinuous { stt.cancelTurn() }
            player.unduck()
            noteDiagnostic("Not an interruption (\(bargeIn.lastReason?.rawValue ?? "?"))")
        case .confirm:
            logger.info("[call] barge-in confirmed: \(self.bargeIn.lastReason?.rawValue ?? "?", privacy: .public) (speech \(Int(self.bargeIn.lastSpeechMs)) ms, novel words \(words, privacy: .public), xecho=\(ratio, privacy: .public))")
            noteDiagnostic("Interrupted (\(bargeIn.lastReason?.rawValue ?? "?"))")
            confirmBargeIn()
        }
    }

    /// The user really is talking over the AI: cancel the reply and continue
    /// the STT turn begun at `.duck`, so their words are kept.
    private func confirmBargeIn() {
        guard phase == .speaking || phase == .processing else { return }
        cancelReply()
        turnId &+= 1
        endingTurn = false
        smartTurnInFlight = false
        lastLoudAt = Date()
        heardSpeechFallback = true
        let start = candidateStartedAt ?? Date()
        turnStartedAt = start
        candidateStartedAt = nil
        // The interrupting words belong to this turn (kept for STT recovery).
        turnAudio.removeAll()
        for f in recentFrames.frames(since: start) { turnAudio.append(f) }
        recentFrames.clear()
        // Keep Silero's state (the user is mid-sentence); restart the window
        // Smart Turn judges on, and seed the turn detector as speaking.
        Task { await vad.resetTurnBuffer() }
        turnDetector.markSpeechInProgress()
        endOfTurn = EndOfTurnPolicy(pace: pauseRange)
        phase = .listening
        startSilenceTimer()
    }
}

/// Short ring of recent mic frames, so an utterance-style STT engine can be
/// handed the audio that triggered a barge-in candidate (never older audio,
/// which would contain the AI's voice).
struct RecentFrames {
    static let seconds: TimeInterval = 3.0
    private var frames: [MicFrame] = []

    mutating func append(_ frame: MicFrame) {
        frames.append(frame)
        let horizon = frame.capturedAt.addingTimeInterval(-Self.seconds)
        if let first = frames.first, first.capturedAt < horizon {
            frames.removeAll { $0.capturedAt < horizon }
        }
    }

    func frames(since date: Date) -> [MicFrame] {
        frames.filter { $0.capturedAt >= date }
    }

    mutating func clear() { frames.removeAll() }
}
