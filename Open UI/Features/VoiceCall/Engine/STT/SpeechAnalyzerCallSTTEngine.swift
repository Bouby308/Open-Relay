import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Speech
import os.log

/// iOS 26+ call recogniser built on `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// One analyzer runs for the **whole call** and hears every mic frame,
/// including while the AI speaks. Results carry per-word audio time ranges,
/// kept in a rolling word log on the call's wall clock. A "turn" is just a
/// window of that log, so:
/// - a barge-in turn can start at the moment the user started talking
///   (`beginTurn(from:)`) — their first words are never lost;
/// - barge-in can compare each heard word against what the AI was saying at
///   that same moment (`words(from:)` → `EchoMatcher`).
///
/// `.volatileResults` + `.fastResults` give low-latency partials that are
/// replaced by final results for the same time range.
@available(iOS 26.0, *)
@MainActor
final class SpeechAnalyzerCallSTTEngine: CallSTTEngine {

    let displayName = "Apple Speech (iOS 26)"
    let providesLivePartials = true
    let isContinuous = true

    fileprivate let logger = Logger(subsystem: "com.openui", category: "SpeechAnalyzerSTT")

    fileprivate var transcriber: SpeechTranscriber?
    fileprivate var analyzer: SpeechAnalyzer?
    fileprivate var analyzerFormat: AVAudioFormat?
    fileprivate var converter: AVAudioConverter?
    fileprivate var converterInput: AVAudioFormat?
    fileprivate var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    fileprivate var resultsTask: Task<Void, Never>?

    /// Wall-clock time that corresponds to audio time 0 of the analyzer.
    fileprivate var epoch: Date?
    /// Analyzer-timeline position of the next sample (seconds of audio fed).
    fileprivate var fedSeconds: Double = 0

    /// Everything recognised this call, kept as the recogniser's own runs.
    fileprivate var log = TranscriptLog()
    /// Audio time (seconds) up to which results are final.
    fileprivate var finalizedThrough: Double = 0

    fileprivate var turnStart: Date = .distantPast
    fileprivate(set) var partialTranscript: String = ""

    /// Words older than this are dropped from the log.
    fileprivate static let memory: TimeInterval = 60

    // MARK: Preparation

    func prepare() async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            logger.error("Speech recognition not authorized")
            return false
        }
        guard SpeechTranscriber.isAvailable else {
            logger.info("SpeechTranscriber unavailable on this device")
            return false
        }
        let saved = UserDefaults.standard.string(forKey: "sttLocale") ?? ""
        let wanted = saved.isEmpty ? Locale.current : Locale(identifier: saved)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            logger.info("SpeechTranscriber doesn't support \(wanted.identifier, privacy: .public)")
            return false
        }
        // `.fastResults` keeps live words arriving quickly — barge-in has a
        // few seconds to see the user's words. (The earlier "random
        // characters" came from how runs were re-joined, not from this.)
        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                logger.info("Downloading speech model for \(locale.identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                logger.error("Speech model not installed for \(locale.identifier, privacy: .public)")
                return false
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                logger.error("No compatible audio format for SpeechTranscriber")
                return false
            }
            let analyzer = SpeechAnalyzer(
                modules: [module],
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            try await analyzer.start(inputSequence: stream)
            self.transcriber = module
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.inputContinuation = continuation
            startResultsLoop(module)
            logger.info("SpeechAnalyzer ready — \(locale.identifier, privacy: .public), \(format.sampleRate, format: .fixed(precision: 0)) Hz")
            return true
        } catch {
            logger.error("SpeechAnalyzer setup failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func startResultsLoop(_ module: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    self?.ingest(result)
                }
            } catch {
                self?.logger.error("SpeechAnalyzer results ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Audio in

@available(iOS 26.0, *)
extension SpeechAnalyzerCallSTTEngine {

    func appendNative(_ buffer: AVAudioPCMBuffer, at time: Date) {
        guard let continuation = inputContinuation, let target = analyzerFormat,
              buffer.frameLength > 0 else { return }
        if epoch == nil { epoch = time }
        guard let converted = convert(buffer, to: target), let epoch else { return }
        // Feed one contiguous stream: each buffer follows the previous one
        // exactly. Tap timestamps jitter by a few ms, and signalling that as a
        // discontinuity on every buffer degrades recognition. Only a real gap
        // (mute / hold / interruption) advances the timeline to the wall clock.
        let wall = time.timeIntervalSince(epoch)
        let position = wall - fedSeconds > Self.gapThreshold ? wall : fedSeconds
        let start = CMTime(seconds: position, preferredTimescale: 48_000)
        fedSeconds = position + Double(converted.frameLength) / target.sampleRate
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Audio gaps shorter than this are treated as continuous.
    fileprivate static let gapThreshold: TimeInterval = 0.2

    func appendVAD(_ samples: [Float]) {}

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}


// MARK: - Results → word log

@available(iOS 26.0, *)
extension SpeechAnalyzerCallSTTEngine {

    fileprivate func ingest(_ result: SpeechTranscriber.Result) {
        guard let epoch else { return }
        log.ingest(Self.segment(from: result, epoch: epoch))
        if result.isFinal {
            finalizedThrough = max(finalizedThrough, result.range.end.seconds)
        }
        partialTranscript = log.text(from: turnStart)
    }

    /// Keeps the result's runs verbatim, each positioned by its
    /// `audioTimeRange` (falls back to the result's range).
    fileprivate static func segment(from result: SpeechTranscriber.Result, epoch: Date) -> TranscriptLog.Segment {
        let text = result.text
        let pieces = text.runs.map { run -> TranscriptLog.Piece in
            let range = run.audioTimeRange ?? result.range
            return TranscriptLog.Piece(
                text: String(text[run.range].characters),
                start: epoch.addingTimeInterval(range.start.seconds),
                end: epoch.addingTimeInterval(range.end.seconds)
            )
        }
        return TranscriptLog.Segment(
            pieces: pieces,
            start: epoch.addingTimeInterval(result.range.start.seconds),
            end: epoch.addingTimeInterval(result.range.end.seconds),
            isFinal: result.isFinal
        )
    }
}


// MARK: - Turns

@available(iOS 26.0, *)
extension SpeechAnalyzerCallSTTEngine {

    func words(from date: Date) -> [TimedWord] {
        log.words(from: date)
    }

    func beginTurn() { beginTurn(from: Date()) }

    func beginTurn(from date: Date) {
        turnStart = date
        partialTranscript = log.text(from: date)
    }

    func finishTurn() async -> String {
        let start = turnStart
        if let analyzer {
            let through = CMTime(seconds: fedSeconds, preferredTimescale: 48_000)
            // Force final results for everything fed so far. Bounded, so a
            // stalled analyzer can never hang the call.
            let finalize = Task { try? await analyzer.finalize(through: through) }
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline, finalizedThrough < through.seconds - 0.05 {
                try? await Task.sleep(for: .milliseconds(40))
            }
            finalize.cancel()
        }
        let text = log.text(from: start)
        turnStart = Date()
        partialTranscript = ""
        return text
    }

    func cancelTurn() {
        turnStart = Date()
        partialTranscript = ""
    }

    func shutdown() {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        transcriber = nil
        log.clear()
    }
}

