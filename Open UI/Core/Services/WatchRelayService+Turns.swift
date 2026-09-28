import Foundation

// MARK: - Turn polling

extension WatchRelayService {

    func poll(_ req: WatchTurnRequest) throws -> WatchTurnState {
        guard let record = turns[req.turnId] else { throw RelayError.bad("This request expired. Try again.") }
        var state = record.state
        let from = min(max(0, req.sentencesFrom), record.sentences.count)
        var batch: [String] = []
        var size = 0
        for sentence in record.sentences[from...] {
            size += sentence.utf8.count
            if !batch.isEmpty && size > 3_000 { break }
            batch.append(sentence)
        }
        state.sentences = batch
        state.sentenceStart = from
        // Only report "done" once every sentence has been handed over.
        if state.phase == .done && from + batch.count < record.sentences.count { state.phase = .streaming }
        state.phoneSpeaking = state.speaksOnPhone && WatchPhoneSpeaker.shared.isSpeaking(turnId: req.turnId)
        return state
    }

    func cancel(turnId: Int) {
        WatchPhoneSpeaker.shared.stop(turnId: turnId)
        Self.clipMaker.discard(turn: turnId)
        guard let record = turns[turnId] else { return }
        record.task?.cancel()
        if record.chat?.isStreaming == true { record.chat?.stopStreaming() }
        if !record.state.isFinished { fail(record, "Stopped") }
    }

    /// One part of the server-voice clip for sentence `index`. `seq` in the
    /// reply is the part count: 0 = still being made, -1 = unavailable
    /// (the watch falls back to its built-in voice for that sentence).
    func replyAudio(_ req: WatchClipRequest) throws -> WatchEnvelope {
        guard turns[req.turnId] != nil else { throw RelayError.bad("This request expired.") }
        switch Self.clipMaker.clip(turn: req.turnId, index: req.index) {
        case .pending:
            return WatchEnvelope(type: .replyAudio, turn: req.turnId, seq: 0)
        case .unavailable:
            return WatchEnvelope(type: .replyAudio, turn: req.turnId, seq: -1)
        case .ready(let parts):
            let part = min(max(0, req.part), parts.count - 1)
            return WatchEnvelope(type: .replyAudio, turn: req.turnId, seq: parts.count, body: parts[part])
        }
    }

    func fail(_ record: TurnRecord, _ message: String) {
        record.state.phase = .failed
        record.state.error = message
        WatchPhoneSpeaker.shared.stop(turnId: record.state.turnId)
    }

    func pruneTurns() {
        let cutoff = Date().addingTimeInterval(-15 * 60)
        turns = turns.filter { $0.value.createdAt > cutoff || !$0.value.state.isFinished }
        // Only the newest few turns keep their voice clips.
        Self.clipMaker.prune(keeping: Set(turns.keys.sorted().suffix(3)))
        if audio.count > 4 {
            let newest = audio.keys.sorted().suffix(2)
            audio = audio.filter { newest.contains($0.key) }
        }
    }
}
