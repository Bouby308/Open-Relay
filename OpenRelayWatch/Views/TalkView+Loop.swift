import SwiftUI
import WatchKit

// MARK: - Conversation loop

extension TalkView {

    func runLoop(startInterrupted: Bool = false) async {
        var misses = 0
        var interrupted = startInterrupted
        while !Task.isCancelled {
            stopListening = false
            let id = turn.beginVoiceTurn(speak: true)
            status = muted ? "Muted" : "Listening…"
            let live = Task { await turn.pollLiveTranscript(id) }
            do {
                let count = try await capture.record(turnId: id, interrupted: interrupted,
                                                     manualStop: { stopListening })
                live.cancel()
                interrupted = false
                status = "Sending…"
                let request = WatchVoiceEndRequest(turnId: id, chatId: turn.chatId, modelId: store.effectiveModelId,
                                                   messageCount: count, speak: true,
                                                   serverVoice: store.usesServerVoice)
                let state = try await WatchLink.shared.request(.voiceEnd, request, as: WatchTurnState.self)
                turn.startedVoiceTurn(id, state: state)
                misses = 0
            } catch is CancellationError {
                live.cancel()
                return
            } catch VoiceCapture.CaptureError.noSpeech {
                live.cancel()
                interrupted = false
                misses += 1
                if misses >= 2 {
                    turn.cancel()
                    goIdle("Tap the orb to talk")
                    return
                }
                continue
            } catch {
                live.cancel()
                turn.fail(message: error.localizedDescription)
                goIdle(error.localizedDescription)
                return
            }
            interrupted = await waitForReply()
        }
    }

    /// Waits for the reply (text + speech). If the user starts talking over
    /// it, the reply stops and this returns true so the loop listens right
    /// away (keeping the words that interrupted).
    @discardableResult
    func waitForReply() async -> Bool {
        let interrupting = store.interruptBySpeaking
        while !Task.isCancelled, turn.isBusy || turn.isSpeaking {
            status = statusText
            if interrupting, turn.isSpeaking {
                let onPhone = turn.speaksOnPhone
                let interrupted = await capture.waitForInterruption(replyOnPhone: onPhone, while: { turn.isSpeaking })
                if interrupted {
                    WKInterfaceDevice.current().play(.directionDown)
                    turn.cancel()
                    return true
                }
            } else {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if case .failed(let message) = turn.phase {
            status = message
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private var statusText: String {
        if turn.isSpeaking {
            if turn.speaksOnPhone { return "Speaking on iPhone" }
            return store.interruptBySpeaking ? "Speaking — talk to interrupt" : "Speaking"
        }
        switch turn.phase {
        case .transcribing: return "Understanding…"
        case .thinking: return "Thinking…"
        case .streaming: return "Answering…"
        default: return "Sending…"
        }
    }
}

