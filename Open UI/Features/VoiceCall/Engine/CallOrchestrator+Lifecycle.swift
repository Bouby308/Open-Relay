import Foundation
import AVFoundation
import os.log

// MARK: - Lifecycle & control

extension CallOrchestrator {

    func start() throws {
        let frames = try audioEngine.start()
        player.refreshRoute()
        frameTask = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.handle(frame)
            }
        }
        let mode = [
            stt.displayName,
            sileroActive ? "voice detection" : "silence timer",
            usesSmartTurn ? "Smart Turn" : nil,
            bargeInEnabled ? "interrupt on" : "interrupt off",
            pauseLabel,
        ].compactMap { $0 }.joined(separator: " · ")
        logger.info("[call] started — \(mode, privacy: .public)")
        if diagnosticsEnabled { diagnostics.mode = mode }
        beginListening()
    }

    func stop() {
        turnId &+= 1
        replyTask?.cancel(); replyTask = nil
        frameTask?.cancel(); frameTask = nil
        silenceTimer?.cancel(); silenceTimer = nil
        speech.shutdown()
        stt.cancelTurn()
        stt.shutdown()
        pendingSTT?.engine.shutdown()
        pendingSTT = nil
        player.saveEchoLearning()
        audioEngine.stop()
        phase = .idle
        logger.info("[call] stopped")
    }

    /// Hold / interruption: stop everything but keep the engine alive.
    func pause() {
        guard phase != .paused, phase != .idle else { return }
        turnId &+= 1
        silenceTimer?.cancel()
        cancelReply()
        stt.cancelTurn()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        if !audioEngine.engine.isRunning { audioEngine.rebuild() }
        beginListening()
    }

    /// Stop the AI mid-reply (interrupt button) and listen again.
    func interrupt() {
        guard phase == .speaking || phase == .processing else { return }
        logger.info("[call] turn \(self.turnId) interrupted by user")
        cancelReply()
        beginListening()
    }

    /// Output route changed (AirPods, speaker toggle, CarPlay…): refresh the
    /// echo tail, latency and per-route echo coupling for the reply in progress.
    func audioRouteChanged() {
        player.refreshRoute()
    }

    /// Swaps the listening engine without losing the user's words:
    /// - mid-turn, the new engine is handed the audio spoken so far;
    /// - while a finished turn is being transcribed, the swap waits for the
    ///   next turn (`pendingSTT`, applied in `beginListening`).
    func replaceSTT(_ newSTT: CallSTTEngine, signature: String) {
        if phase == .processing {
            if let old = pendingSTT?.engine, old !== newSTT { old.shutdown() }
            pendingSTT = (newSTT, signature)
            logger.info("[call] STT → \(newSTT.displayName, privacy: .public) (after this turn)")
            return
        }
        let old = stt
        stt = newSTT
        sttSignature = signature
        old.cancelTurn()
        old.shutdown()
        if phase == .listening {
            newSTT.beginTurn(from: turnStartedAt)
            for f in turnAudio.frames {
                newSTT.appendNative(f.native, at: f.capturedAt)
                if !f.vadSamples.isEmpty { newSTT.appendVAD(f.vadSamples) }
            }
        }
        logger.info("[call] STT → \(newSTT.displayName, privacy: .public)")
        onEnginesChanged?()
    }

    /// Installs a listening engine that was waiting for the turn to finish.
    func applyPendingSTT() {
        guard let pending = pendingSTT else { return }
        pendingSTT = nil
        let old = stt
        stt = pending.engine
        sttSignature = pending.signature
        if old !== pending.engine { old.cancelTurn(); old.shutdown() }
        logger.info("[call] STT → \(pending.engine.displayName, privacy: .public)")
        onEnginesChanged?()
    }

    /// Cancels the reply being generated / played. Only the reply's own
    /// server task is stopped — never "all tasks for this chat", which could
    /// arrive late and kill the next turn's reply.
    func cancelReply() {
        if chat?.isStreaming == true { chat?.stopStreaming(stopAllChatTasks: false) }
        replyTask?.cancel()
        speech.cancel()
        bargeIn.stopMonitoring()
    }

    /// Words the AI played recently enough that they may be echo right now.
    func recentAIText() -> [String] {
        player.timeline.recentSpokenText(within: Self.echoTextWindow)
    }
}
