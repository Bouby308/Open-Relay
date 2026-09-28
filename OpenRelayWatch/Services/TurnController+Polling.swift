import Foundation
import WatchKit

// MARK: - Polling the iPhone for reply progress

extension TurnController {

    func pollUntilDone(_ id: Int) async {
        var failures = 0
        while !Task.isCancelled, turnId == id {
            try? await Task.sleep(for: .milliseconds(phase == .streaming ? 450 : 700))
            guard !Task.isCancelled, turnId == id else { return }
            do {
                let req = WatchTurnRequest(turnId: id, sentencesFrom: nextSentence)
                let state = try await WatchLink.shared.request(.pollTurn, req, as: WatchTurnState.self, attempts: 1)
                guard turnId == id else { return }
                failures = 0
                apply(state)
                let phoneStillSpeaking = state.speaksOnPhone && state.phoneSpeaking
                if state.isFinished && !phoneStillSpeaking { break }
            } catch let error as LinkError where !error.isTransient {
                fail(error, turn: id)
                return
            } catch {
                // Wrist down / brief disconnect: keep trying until it's back.
                failures += 1
                if failures > 90 { fail(LinkError.unreachable, turn: id); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard turnId == id else { return }
        WidgetBridge.setReplyInProgress(false)
        if case .done = phase {
            if !isAppActive { ReplyNotifier.replyReady(chatId: chatId, title: chatTitle, preview: reply) }
            if followUps.isEmpty { Task { await pollFollowUps(id) } }
        }
        if speaksOnPhone { isSpeaking = false } else { await waitForSpeech(id) }
    }

    /// Follow-ups arrive a moment after the reply — ask a few more times.
    private func pollFollowUps(_ id: Int) async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            guard turnId == id, followUps.isEmpty, !Task.isCancelled else { return }
            let req = WatchTurnRequest(turnId: id, sentencesFrom: Int.max / 2)
            guard let state = try? await WatchLink.shared.request(.pollTurn, req, as: WatchTurnState.self, attempts: 1)
            else { continue }
            if !state.followUps.isEmpty, turnId == id { followUps = state.followUps; return }
        }
    }

    private var isAppActive: Bool {
        WKApplication.shared().applicationState == .active
    }

    /// Keeps `isSpeaking` accurate until the watch finishes reading aloud.
    private func waitForSpeech(_ id: Int) async {
        while speaker.isSpeaking, turnId == id, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(300))
        }
        if turnId == id { isSpeaking = false }
    }

    func apply(_ state: WatchTurnState) {
        if let p = state.prompt { prompt = p }
        if let partial = state.partialTranscript, !partial.isEmpty { liveTranscript = partial }
        if !state.followUps.isEmpty { followUps = state.followUps }
        if !state.reply.isEmpty {
            if hapticForFirstText {
                hapticForFirstText = false
                WKInterfaceDevice.current().play(.directionUp)
            }
            reply = state.reply
        }
        if let id = state.chatId { chatId = id }
        if let t = state.chatTitle, !t.isEmpty { chatTitle = t }
        speaksOnPhone = state.speaksOnPhone
        if state.speaksOnPhone {
            isSpeaking = state.phoneSpeaking
        } else if speakThisTurn, state.sentenceStart == nextSentence, !state.sentences.isEmpty {
            speaker.enqueue(state.sentences, startIndex: nextSentence)
            nextSentence += state.sentences.count
            isSpeaking = true
        }
        switch state.phase {
        case .transcribing: phase = .transcribing
        case .thinking: phase = .thinking
        case .streaming: phase = .streaming
        case .done:
            guard phase != .done else { return }
            phase = .done
            WKInterfaceDevice.current().play(.success)
            if let id = chatId { WatchStore.shared.noteChat(id: id, title: chatTitle, preview: reply) }
        case .failed:
            phase = .failed(state.error ?? "Something went wrong.")
            WKInterfaceDevice.current().play(.failure)
            WidgetBridge.setReplyInProgress(false)
        }
    }
}
