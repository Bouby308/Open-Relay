import Foundation
import AVFoundation
import UIKit
import os.log

/// Reads watch replies aloud on the **iPhone** — used when headphones
/// (AirPods, car, wired) are connected to the iPhone, so the reply keeps
/// playing even after the watch screen sleeps.
///
/// Uses the same voice as Read Aloud / Voice Call. On-device neural voices
/// are only used while the iPhone app is in the foreground (GPU work isn't
/// allowed in the background); otherwise server voice, then the system voice.
@MainActor
final class WatchPhoneSpeaker {

    static let shared = WatchPhoneSpeaker()

    /// "auto" | "phone" | "watch" — Settings → Apple Watch → Spoken replies.
    static let outputKey = "watch.replyOutput"

    let logger = Logger(subsystem: "com.openui", category: "WatchSpeaker")
    var turnId: Int?
    var queue: [String] = []
    var inputDone = false
    var worker: Task<Void, Never>?
    var tts: CallTTSEngine?
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    var format: AVAudioFormat?
    var pendingBuffers = 0

    private init() { engine.attach(player) }

    /// True when replies for the watch should be spoken by the iPhone.
    var shouldSpeakOnPhone: Bool {
        guard !CallAudioSession.isCallActive else { return false }
        switch UserDefaults.standard.string(forKey: Self.outputKey) ?? "auto" {
        case "phone": return true
        case "watch": return false
        default: return Self.headphonesOnPhone
        }
    }

    static var headphonesOnPhone: Bool {
        let personal: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .carAudio, .airPlay, .usbAudio
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { personal.contains($0.portType) }
    }

    func isSpeaking(turnId id: Int) -> Bool {
        turnId == id && (worker != nil || pendingBuffers > 0 || !queue.isEmpty)
    }

    func begin(turnId id: Int) {
        stopPlayback()
        turnId = id
        inputDone = false
    }

    func enqueue(_ sentences: [String], turnId id: Int) {
        guard turnId == id else { return }
        queue.append(contentsOf: sentences)
        startWorker()
    }

    func finishInput(turnId id: Int) {
        guard turnId == id else { return }
        inputDone = true
        if worker == nil && pendingBuffers == 0 { finish() }
    }

    func stop(turnId id: Int) {
        guard turnId == id else { return }
        stopPlayback()
        turnId = nil
    }

    private func startWorker() {
        guard worker == nil, let id = turnId else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            if self.tts == nil { self.tts = await self.makeEngine() }
            while let sentence = self.queue.first, self.turnId == id, !Task.isCancelled {
                self.queue.removeFirst()
                await self.speak(sentence, turn: id)
            }
            self.worker = nil
            if self.turnId == id && self.inputDone && self.pendingBuffers == 0 { self.finish() }
        }
    }

    private func makeEngine() async -> CallTTSEngine {
        guard let deps = WatchRelayService.shared.dependencies else { return CallEngineFactory.makeSystemTTS() }
        let tts = deps.textToSpeechService
        if UIApplication.shared.applicationState == .active {
            return await CallEngineFactory.makeTTS(settings: deps.voiceCallSettings, apiClient: deps.apiClient, ttsService: tts)
        }
        if tts.preferredEngine != .system, let api = deps.apiClient {
            let server = ServerCallTTSEngine(apiClient: api, voice: tts.serverVoiceId, model: tts.serverModel)
            if await server.prepare() { return server }
        }
        return CallEngineFactory.makeSystemTTS()
    }

    private func speak(_ sentence: String, turn id: Int) async {
        guard let tts else { return }
        do {
            for try await chunk in tts.synthesize(sentence) {
                guard turnId == id else { return }
                schedule(chunk)
            }
        } catch {
            logger.error("Watch reply TTS failed: \(error.localizedDescription, privacy: .public)")
            if !(tts is SystemCallTTSEngine) { self.tts = CallEngineFactory.makeSystemTTS() }
        }
    }
}
