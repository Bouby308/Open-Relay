import Foundation
import AVFoundation
import os.log

// MARK: - Voice input (watch mic → transcript)

extension WatchRelayService {

    func receiveAudio(_ envelope: WatchEnvelope) throws -> WatchEnvelope {
        guard isEnabled else { throw RelayError.needsPhone("Apple Watch access is off on your iPhone.") }
        guard let turn = envelope.turn, let seq = envelope.seq else { throw RelayError.bad("Bad audio") }
        if audio[turn] == nil { pruneTurns() }
        audio[turn, default: [:]][seq] = envelope.body
        Self.liveTranscriber.feed(turn: turn, seq: seq, pcm: envelope.body)
        let ack = WatchAudioAck(seq: seq, bytes: envelope.body.count)
        return try WatchEnvelope.make(.audioAck, payload: ack, turn: turn, seq: seq)
    }

    /// Live words for the voice turn being recorded (best-effort).
    func liveTranscript(_ req: WatchLiveRequest) -> WatchTurnState {
        var state = WatchTurnState(turnId: req.turnId, phase: .transcribing, prompt: nil, reply: "",
                                   sentences: [], sentenceStart: 0, chatId: nil, chatTitle: nil, error: nil)
        state.partialTranscript = Self.liveTranscriber.partial(for: req.turnId)
        return state
    }

    func finishVoice(_ req: WatchVoiceEndRequest) async throws -> WatchTurnState {
        if let existing = turns[req.turnId] { return existing.state }  // retried request
        Self.liveTranscriber.finish(turn: req.turnId)
        let deps = try await ready()
        let parts = audio[req.turnId] ?? [:]
        var pcm = Data()
        for index in 0..<req.messageCount {
            guard let part = parts[index] else { throw RelayError.bad("Some audio didn't arrive. Try again.") }
            pcm.append(part)
        }
        audio[req.turnId] = nil
        let record = TurnRecord(state: WatchTurnState(
            turnId: req.turnId, phase: .transcribing, prompt: nil, reply: "", sentences: [],
            sentenceStart: 0, chatId: req.chatId, chatTitle: nil, error: nil))
        turns[req.turnId] = record
        record.serverVoice = req.speak && req.serverVoice
        beginWork()
        record.task = Task { [weak self] in
            guard let self else { return }
            defer { self.endWork() }
            let text = await self.transcribe(pcm, deps: deps)
            guard !Task.isCancelled else { return }
            guard !text.isEmpty else { return self.fail(record, "Didn't catch that.") }
            record.state.prompt = text
            record.state.phase = .thinking
            await self.run(record, text: text, chatId: req.chatId, modelId: req.modelId,
                           voice: true, speak: req.speak, deps: deps)
        }
        return record.state
    }

    /// Transcribes 16 kHz Int16 mono PCM. Uses the server when Voice Call is
    /// set to server speech recognition, otherwise Apple Speech (server as
    /// backup). On-device MLX engines aren't used: the app is usually in the
    /// background here, where GPU work isn't allowed.
    private func transcribe(_ pcm: Data, deps: AppDependencyContainer) async -> String {
        let count = pcm.count / 2
        guard count > 4_800 else { return "" }  // < 0.3 s
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                samples[i] = Float(value) / 32_768
            }
        }
        let preferServer = deps.voiceCallSettings.sttEngine == "server"
        if preferServer, let api = deps.apiClient,
           let text = await serverTranscribe(samples, api: api), !text.isEmpty {
            return text
        }
        if let text = await appleTranscribe(samples), !text.isEmpty { return text }
        if !preferServer, let api = deps.apiClient { return await serverTranscribe(samples, api: api) ?? "" }
        return ""
    }

    private func serverTranscribe(_ samples: [Float], api: APIClient) async -> String? {
        let wav = UtteranceSTTEngine.wavData(from: samples)
        do {
            let result = try await api.transcribeSpeech(audioData: wav, fileName: "watch.wav")
            return (result["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("⌚️ Server transcription failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func appleTranscribe(_ samples: [Float]) async -> String? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: WatchProtocol.audioSampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { channel[i] = s }
        let engine = AppleCallSTTEngine()
        guard await engine.prepare() else { return nil }
        engine.beginTurn()
        engine.appendNative(buffer, at: Date())
        let text = await engine.finishTurn()
        engine.shutdown()
        return text
    }
}
