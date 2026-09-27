import Foundation
import os.log

// MARK: - Listening & end of turn

extension CallOrchestrator {

    func beginListening() {
        turnId &+= 1
        endingTurn = false
        smartTurnInFlight = false
        turnDetector.reset()
        endOfTurn = EndOfTurnPolicy(pace: pauseRange)
        bargeIn.stopMonitoring()
        lastLoudAt = nil
        heardSpeechFallback = false
        turnStartedAt = Date()
        Task { await vad.reset() }
        stt.beginTurn()
        onPartialTranscript?("")
        phase = .listening
        startSilenceTimer()
    }

    /// Model-free end-of-turn: a timer (not audio callbacks) decides, so it
    /// still fires if the mic goes quiet or frames stop arriving.
    func startSilenceTimer() {
        silenceTimer?.cancel()
        guard !sileroActive else { return }
        let id = turnId
        silenceTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, id == self.turnId, self.phase == .listening else { return }
                guard !self.isMicMuted, self.heardSpeechFallback, let last = self.lastLoudAt else { continue }
                let quiet = Date().timeIntervalSince(last)
                if self.diagnosticsEnabled {
                    self.diagnostics.pause = quiet
                    self.diagnostics.requiredPause = self.fallbackSilence
                }
                if quiet >= self.fallbackSilence {
                    self.noteDiagnostic(String(format: "Turn ended after %.1fs silence", quiet))
                    self.endTurn()
                    return
                }
            }
        }
    }

    // MARK: Mic frames

    func handle(_ frame: MicFrame) async {
        guard !isMicMuted else { onLevel?(0); return }
        onLevel?(frame.rms)
        switch phase {
        case .listening:
            await handleListening(frame)
        case .speaking, .processing:
            await handleDuringReply(frame)
        case .idle, .paused:
            break
        }
    }

    private func handleListening(_ frame: MicFrame) async {
        stt.appendNative(frame.native, at: frame.capturedAt)
        if !frame.vadSamples.isEmpty { stt.appendVAD(frame.vadSamples) }
        if !stt.partialTranscript.isEmpty { onPartialTranscript?(stt.partialTranscript) }

        // While the AI's tail may still be in the mic, level alone can't start
        // a turn in the fallback path — the transcript echo check at turn end
        // decides.
        if frame.rms >= Self.fallbackLevelThreshold, !player.timeline.isAIAudible() {
            lastLoudAt = Date()
            heardSpeechFallback = true
        }
        guard sileroActive, !frame.vadSamples.isEmpty else { return }
        let id = turnId
        guard let probs = await vad.process(frame.vadSamples) else { sileroUnavailable(); return }
        guard id == turnId, phase == .listening, !endingTurn else { return }
        for p in probs {
            for event in turnDetector.processChunk(probability: p) {
                switch event {
                case .speechStarted:
                    logger.debug("[call] turn \(id) speech started")
                    noteDiagnostic("Hearing you")
                case .speechResumed:
                    endOfTurn.speechResumed()
                }
            }
            if diagnosticsEnabled { diagnostics.speechProbability = p }
            guard turnDetector.hasSpeech, turnDetector.pause > 0 else {
                if diagnosticsEnabled, diagnostics.pause != 0 { diagnostics.pause = 0 }
                continue
            }
            let pause = turnDetector.pause
            if diagnosticsEnabled {
                diagnostics.pause = pause
                diagnostics.requiredPause = usesSmartTurn ? endOfTurn.currentRequiredPause : pauseRange.fallbackSilence
                diagnostics.smartTurn = endOfTurn.lastProbability
            }
            switch endOfTurn.update(pause: pause, smartTurnAvailable: usesSmartTurn) {
            case .wait:
                break
            case .evaluate:
                evaluateEndOfTurn(turn: id)
            case .endTurn:
                logger.info("[call] turn \(id) ended after \(String(format: "%.2f", pause))s pause (Smart Turn p=\(self.endOfTurn.lastProbability.map { String(format: "%.2f", $0) } ?? "–", privacy: .public), pace \(self.pauseLabel, privacy: .public))")
                noteDiagnostic(String(format: "Turn ended after %.1fs pause", pause))
                endTurn()
                return
            }
        }
    }

    /// Smart Turn is loaded and enabled for this call.
    var usesSmartTurn: Bool { smartTurnEnabled && vad.hasSmartTurn }

    /// Records a human-readable turn-taking event for the diagnostics readout.
    func noteDiagnostic(_ event: String) {
        guard diagnosticsEnabled else { return }
        diagnostics.lastEvent = event
    }

    /// Silero failed at runtime: switch this call to the RMS level + silence
    /// timer. Barge-in needs Silero, so it stays off until the next call.
    func sileroUnavailable() {
        guard sileroActive else { return }
        sileroActive = false
        logger.error("[call] Silero unavailable — falling back to level-based turn detection")
        if phase == .listening {
            heardSpeechFallback = turnDetector.hasSpeech
            if heardSpeechFallback { lastLoudAt = Date() }
            turnDetector.reset()
            startSilenceTimer()
        }
    }

    /// Pause in progress: ask Smart Turn (on the whole turn so far) how likely
    /// it is the user has finished. The policy turns that into how long to wait.
    private func evaluateEndOfTurn(turn id: Int) {
        guard !smartTurnInFlight else { return }
        smartTurnInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let prob = await self.vad.evaluateEndOfTurn()
            self.smartTurnInFlight = false
            guard id == self.turnId, self.phase == .listening, !self.endingTurn else { return }
            let pause = self.turnDetector.pause
            // The user spoke again while Smart Turn ran: its verdict is stale.
            guard pause > 0 else { self.endOfTurn.speechResumed(); return }
            let decision = self.endOfTurn.smartTurnResult(prob, pause: pause)
            self.logger.debug("[call] turn \(id) end-of-turn p=\(prob ?? -1, format: .fixed(precision: 2)) pause=\(pause, format: .fixed(precision: 2))s → need \(self.endOfTurn.currentRequiredPause, format: .fixed(precision: 2))s")
            if self.diagnosticsEnabled {
                self.diagnostics.smartTurn = prob
                self.diagnostics.requiredPause = self.endOfTurn.currentRequiredPause
            }
            if decision == .endTurn {
                self.logger.info("[call] turn \(id) ended after \(String(format: "%.2f", pause))s pause (Smart Turn p=\(String(format: "%.2f", prob ?? -1), privacy: .public), pace \(self.pauseLabel, privacy: .public))")
                self.noteDiagnostic(String(format: "Turn ended after %.1fs pause", pause))
                self.endTurn()
            }
        }
    }

    /// The user finished talking: transcribe, drop the AI's own echo, send.
    func endTurn() {
        guard phase == .listening, !endingTurn else { return }
        if turnDetector.isTooShortToCount {
            logger.debug("[call] turn \(self.turnId) too short — ignored")
            beginListening()
            return
        }
        endingTurn = true
        silenceTimer?.cancel()
        let id = turnId
        let turnStart = turnStartedAt
        let spoken = Date().timeIntervalSince(turnStart)
        // Captured now: what the AI said just before / during this turn.
        let aiText = recentAIText()
        phase = .processing
        Task { [weak self] in
            guard let self else { return }
            let t0 = Date()
            // Continuous engines: take the timed words for the turn window
            // before finishTurn() resets it, for timing-based echo checks.
            let text = await self.stt.finishTurn().trimmingCharacters(in: .whitespacesAndNewlines)
            let heard = self.stt.words(from: turnStart)
            guard id == self.turnId else { return }
            self.logger.info("[call] turn \(id) STT \(String(format: "%.2f", Date().timeIntervalSince(t0)))s after \(String(format: "%.1f", spoken))s listening — \(text.count) chars")
            guard !text.isEmpty else { self.beginListening(); return }

            let verdict: EchoMatcher.Verdict
            if self.stt.isContinuous, !heard.isEmpty {
                let aiWords = self.player.timeline.spokenWords(from: turnStart, to: Date())
                verdict = EchoMatcher.evaluate(heard: heard, spoken: aiWords)
            } else {
                verdict = EchoMatcher.evaluate(transcript: text, against: aiText)
            }
            if verdict.isEcho {
                self.logger.info("[call] turn \(id) dropped — only the AI's own speech (\(verdict.echoTokens) echo / \(verdict.novelTokens) novel words)")
                self.beginListening()
                return
            }
            self.onUserTurn?(text)
            self.sendAndSpeak(text, turn: id)
        }
    }
}
