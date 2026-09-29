import Foundation
import os.log

// MARK: - Barge-in

extension CallOrchestrator {

    /// Mic level below which nothing counts as speech (self-noise).
    static let micNoiseFloor: Float = 0.003

    /// Mic frame while a reply is being generated or played. The AI may be in
    /// the mic, so audio only ever feeds barge-in detection — never a turn —
    /// until the arbiter confirms the user is really talking.
    func handleDuringReply(_ frame: MicFrame) async {
        // Continuous engines hear everything (word log with timings); echo is
        // judged later against what the AI was saying at those moments.
        recentFrames.append(frame)
        if stt.isContinuous {
            stt.appendNative(frame.native, at: frame.capturedAt)
        } else {
            if bargeIn.isCandidate {
                stt.appendNative(frame.native, at: frame.capturedAt)
                if !frame.vadSamples.isEmpty { stt.appendVAD(frame.vadSamples) }
            }
        }
        guard bargeInEnabled, bargeIn.isMonitoring, sileroActive, !frame.vadSamples.isEmpty else { return }
        let id = turnId
        guard let probs = await vad.process(frame.vadSamples) else { sileroUnavailable(); return }
        guard id == turnId, phase == .speaking || phase == .processing else { return }

        let ratio = player.echo.ratioAboveEcho(micLevel: frame.rms, at: frame.capturedAt,
                                               noiseFloor: Self.micNoiseFloor)
        if diagnosticsEnabled { diagnostics.echoRatio = ratio }
        let words = bargeIn.isCandidate ? candidateWords() : (novel: 0, echo: 0)
        for p in probs {
            // Learn residual echo from frames that are the AI alone.
            if !bargeIn.isCandidate, p < bargeIn.config.speechThreshold {
                player.echo.learn(micLevel: frame.rms, at: frame.capturedAt)
            }
            let obs = BargeInDetector.Observation(
                probability: p, ratioAboveEcho: ratio,
                novelWords: stt.providesLivePartials ? words.novel : nil,
                echoWords: stt.providesLivePartials ? words.echo : 0
            )
            guard let event = bargeIn.process(obs) else { continue }
            handleBargeIn(event, frame: frame, observation: obs)
            if event == .confirm { return }
        }
    }

    /// Words heard since the candidate started: how many the AI wasn't
    /// saying (the user's) and how many were the AI's own voice leaking back.
    private func candidateWords() -> (novel: Int, echo: Int) {
        guard let start = candidateStartedAt else { return (0, 0) }
        let now = Date()
        let verdict: EchoMatcher.Verdict
        if stt.isContinuous {
            let heard = stt.words(from: start)
            let spoken = player.timeline.spokenWords(from: start, to: now)
            verdict = EchoMatcher.evaluate(heard: heard, spoken: spoken)
        } else {
            let partial = stt.partialTranscript
            guard !partial.isEmpty else { return (0, 0) }
            let spokenText = player.timeline.recentSpokenText(within: now.timeIntervalSince(start) + 1)
            verdict = EchoMatcher.evaluate(transcript: partial, against: spokenText)
        }
        return (verdict.novelTokens, verdict.echoTokens)
    }
}
