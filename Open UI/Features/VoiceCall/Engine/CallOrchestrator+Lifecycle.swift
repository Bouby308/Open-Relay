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

    func replaceSTT(_ newSTT: CallSTTEngine) {
        stt.cancelTurn()
        stt.shutdown()
        stt = newSTT
        logger.info("[call] STT → \(newSTT.displayName, privacy: .public)")
        if phase == .listening { beginListening() }
    }

    /// Cancels the reply being generated / played.
    func cancelReply() {
        chat?.stopStreaming()
        replyTask?.cancel()
        speech.cancel()
        bargeIn.stopMonitoring()
    }

    /// Words the AI played recently enough that they may be echo right now.
    func recentAIText() -> [String] {
        player.timeline.recentSpokenText(within: Self.echoTextWindow)
    }
}
