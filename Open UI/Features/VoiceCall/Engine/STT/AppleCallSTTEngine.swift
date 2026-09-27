import Foundation
import AVFoundation
import Speech
import os.log

/// Apple Speech recognizer fed from the shared call mic tap.
/// Does NOT create its own AVAudioEngine or touch the audio session.
@MainActor
final class AppleCallSTTEngine: CallSTTEngine {

    let displayName = "Apple Speech"
    let providesLivePartials = true
    private(set) var partialTranscript: String = ""

    private let logger = Logger(subsystem: "com.openui", category: "AppleCallSTT")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var bestTranscript: String = ""
    /// Bumped every turn; async callbacks from older turns are dropped.
    private var turnToken = 0

    func prepare() async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            logger.error("Speech recognition not authorized")
            return false
        }
        let saved = UserDefaults.standard.string(forKey: "sttLocale") ?? ""
        recognizer = saved.isEmpty
            ? SFSpeechRecognizer(locale: Locale.current)
            : SFSpeechRecognizer(locale: Locale(identifier: saved))
        return recognizer?.isAvailable ?? false
    }

    func beginTurn() {
        cancelTurn()
        guard let recognizer else { return }
        turnToken &+= 1
        let token = turnToken
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        bestTranscript = ""
        partialTranscript = ""
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                // Callbacks from a previous turn's task are ignored.
                guard let self, token == self.turnToken else { return }
                if let text, !text.isEmpty {
                    self.bestTranscript = text
                    self.partialTranscript = text
                }
                if isFinal || failed { self.resolveFinal(token: token) }
            }
        }
    }

    func appendNative(_ buffer: AVAudioPCMBuffer, at time: Date) {
        request?.append(buffer)
    }

    func appendVAD(_ samples: [Float]) {}

    func finishTurn() async -> String {
        guard request != nil else { return bestTranscript }
        let token = turnToken
        request?.endAudio()
        let result: String = await withCheckedContinuation { c in
            finalContinuation = c
            // Safety net: Apple may never deliver isFinal for silent audio.
            // Token-scoped so it can never resolve a later turn.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.resolveFinal(token: token)
            }
        }
        return result
    }

    func cancelTurn() {
        let token = turnToken
        task?.cancel()
        task = nil
        request = nil
        resolveFinal(token: token)
    }

    func shutdown() {
        cancelTurn()
        recognizer = nil
    }

    private func resolveFinal(token: Int) {
        guard token == turnToken, let c = finalContinuation else { return }
        finalContinuation = nil
        let text = bestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        task = nil
        request = nil
        c.resume(returning: text)
    }
}
