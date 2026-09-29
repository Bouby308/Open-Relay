import Foundation
import os.log

// MARK: - Reply playback

extension CallOrchestrator {

    func sendAndSpeak(_ text: String, turn id: Int) {
        guard let chat else { beginListening(); return }
        replyTask?.cancel()
        Task { await vad.reset() }
        // Barge-in while thinking: nothing is playing, so the echo reference
        // predicts no echo and any real speech passes the level check.
        if bargeInEnabled { bargeIn.startMonitoring() }
        speech.begin()
        let sentAt = Date()
        logger.info("[call] turn \(id) sending \(text.count) chars")
        replyTask = Task { [weak self] in
            guard let self else { return }
            // Snapshot per attempt: a retry must not mistake nothing for a reply.
            var known = ResponseTextStream.assistantIds(in: chat)
            var sendDone = false
            var accepted = false
            var sendTask = Task { @MainActor in
                accepted = await chat.sendMessage(directText: text)
                sendDone = true
            }
            // A send that was rejected before starting (busy, stale state) is
            // retried once after a short pause, instead of silently returning
            // to listening with the user's words thrown away.
            await sendTask.value
            guard id == self.turnId, !Task.isCancelled else { return }
            if !accepted, chat.lastSendBlockReason?.isTransient == true {
                self.logger.info("[call] turn \(id) send rejected (busy) — retrying")
                try? await Task.sleep(for: .milliseconds(400))
                guard id == self.turnId, !Task.isCancelled else { return }
                known = ResponseTextStream.assistantIds(in: chat)
                sendDone = false
                sendTask = Task { @MainActor in
                    accepted = await chat.sendMessage(directText: text)
                    sendDone = true
                }
                await sendTask.value
                guard id == self.turnId, !Task.isCancelled else { return }
            }
            guard accepted else {
                let reason = chat.lastSendBlockReason.map { "\($0)" } ?? "unknown"
                self.logger.error("[call] turn \(id) send not accepted — \(reason, privacy: .public)")
                self.onError?(Self.message(for: chat.lastSendBlockReason, chat: chat))
                self.speech.cancel()
                self.beginListening()
                return
            }
            self.logger.info("[call] turn \(id) send accepted after \(String(format: "%.2f", Date().timeIntervalSince(sentAt)))s")
            var chunker = SentenceChunker()
            var latest = ""
            var firstTextLogged = false
            for await full in ResponseTextStream.stream(
                for: chat, knownAssistantIds: known, sendFinished: { sendDone }
            ) {
                guard id == self.turnId, !Task.isCancelled else { return }
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
            if latest.isEmpty {
                self.logger.error("[call] turn \(id) reply ended with no speakable text")
                if let err = chat.errorMessage, !err.isEmpty { self.onError?(err) }
            }
            self.speech.finishInput()
        }
    }

    /// User-facing explanation for a turn that couldn't be sent.
    static func message(for reason: ChatViewModel.SendBlockReason?, chat: ChatViewModel) -> String {
        if let err = chat.errorMessage, !err.isEmpty { return err }
        switch reason {
        case .webSearch: return "Web search needs your approval. Turn it off or approve it, then try again."
        case .needsInput: return "This chat needs input (a tool sign-in or chat variables). Open the chat to finish, then try again."
        case .busy: return "The chat was busy — please say that again."
        default: return "Couldn't send that — please try again."
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
