import Foundation
import os.log

// MARK: - Reply playback

extension CallOrchestrator {

    func sendAndSpeak(_ text: String, turn id: Int) {
        guard let chat else { beginListening(); return }
        replyTask?.cancel()
        let known = ResponseTextStream.assistantIds(in: chat)
        Task { await vad.reset() }
        // Barge-in while thinking: nothing is playing, so the echo reference
        // predicts no echo and any real speech passes the level check.
        if bargeInEnabled { bargeIn.startMonitoring() }
        speech.begin()
        let sentAt = Date()
        replyTask = Task { [weak self] in
            guard let self else { return }
            var sendDone = false
            let sendTask = Task { @MainActor in
                await chat.sendMessage(directText: text)
                sendDone = true
            }
            var chunker = SentenceChunker()
            var latest = ""
            var firstTextLogged = false
            for await full in ResponseTextStream.stream(
                for: chat, knownAssistantIds: known, sendFinished: { sendDone }
            ) {
                guard id == self.turnId, !Task.isCancelled else { sendTask.cancel(); return }
                if !firstTextLogged, !full.isEmpty {
                    firstTextLogged = true
                    self.logger.info("[call] turn \(id) first reply text after \(String(format: "%.2f", Date().timeIntervalSince(sentAt)))s")
                }
                // Only the reply prose is spoken — tool calls, reasoning and
                // code (complete or still streaming) are filtered out.
                let speakable = SpeakableReplyFilter.filter(full)
                latest = speakable
                self.onReplyText?(speakable)
                self.speech.enqueue(chunker.feed(speakable))
            }
            guard id == self.turnId, !Task.isCancelled else { return }
            self.speech.enqueue(chunker.flush(latest))
            if latest.isEmpty, let err = chat.errorMessage, !err.isEmpty {
                self.onError?(err)
            }
            self.speech.finishInput()
        }
    }

    func speakingStarted() {
        guard phase == .processing || phase == .speaking else { return }
        if phase == .processing { logger.info("[call] turn \(self.turnId) speaking") }
        phase = .speaking
    }

    /// The device has finished playing the reply (`.dataPlayedBack`).
    func speakingFinished() {
        guard phase == .speaking || phase == .processing else { return }
        logger.info("[call] turn \(self.turnId) reply finished")
        beginListening()
    }
}
