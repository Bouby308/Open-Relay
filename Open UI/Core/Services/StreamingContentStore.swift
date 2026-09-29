import Foundation
import SwiftUI

/// Estimates a delivery rate in characters per second from irregular arrivals.
///
/// Each arrival adds its characters to an exponentially decayed sum (about a
/// 0.6s window). Uneven packet sizes and spacing then average out, where a
/// per-packet estimate jumps with every burst. The first arrival only starts the
/// clock: its characters built up before the stream was observed, and counting
/// them would inflate the early estimate.
struct ArrivalRateEstimator {
    private static let window = 0.6
    private var decayed = 0.0
    private var firstTime: Double?
    private var lastTime: Double?

    mutating func record(_ characters: Int, now: Double) {
        guard characters > 0 else { return }
        guard let lastTime else {
            firstTime = now
            self.lastTime = now
            return
        }
        decayed = decayed * exp(-max(0, now - lastTime) / Self.window) + Double(characters)
        self.lastTime = now
    }

    /// Characters per second, or nil until there is enough to measure.
    func rate(now: Double) -> Double? {
        guard let firstTime, let lastTime, decayed > 0 else { return nil }
        let span = now - firstTime
        guard span > 0.05 else { return nil }
        let current = decayed * exp(-max(0, now - lastTime) / Self.window)
        // Early on the window has not filled yet; scale up for the covered part.
        let coverage = 1 - exp(-span / Self.window)
        return current / (Self.window * coverage)
    }
}

/// Measures how fast the server is delivering the reply that is streaming now.
///
/// Typewriters read this instead of estimating speed from the updates they
/// receive. Those arrive in parse-sized batches, and a text section that appears
/// partway through a reply would otherwise start from a guess. Deliberately not
/// observable: reading it never causes a view update.
@MainActor
final class StreamRateMeter {
    private var estimator = ArrivalRateEstimator()
    private var lastBytes = 0

    func reset(existingContent: String = "") {
        estimator = ArrivalRateEstimator()
        lastBytes = existingContent.utf8.count
    }

    func record(_ content: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        let bytes = content.utf8.count
        guard bytes > lastBytes else {
            lastBytes = bytes
            return
        }
        // Count characters in the appended bytes only: O(new text), not O(reply).
        let added = String(decoding: content.utf8.suffix(bytes - lastBytes), as: UTF8.self).count
        lastBytes = bytes
        estimator.record(added, now: now)
    }

    func rate(now: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
        estimator.rate(now: now)
    }
}

extension EnvironmentValues {
    /// Delivery rate of the reply being streamed, for typewriters in that reply.
    @Entry var streamRateMeter: StreamRateMeter? = nil
}

/// Publishes off-main streaming analysis to the view layer.
@MainActor @Observable
final class StreamingContentStore {
    var streamingMessageId: String?
    var displayContent = ""
    var frozenContent = ""
    var liveTail = ""
    var streamingStatusHistory: [ChatStatusUpdate] = []
    var streamingSources: [ChatSourceReference] = []
    var streamingError: ChatMessageError?
    var isActive = false
    var isFinishing: Bool { isActive && updates == nil }
    var streamingModelId: String?
    /// How fast the current reply is arriving. Not observed.
    @ObservationIgnored let rateMeter = StreamRateMeter()

    private struct Update: Sendable {
        let content: String
        let isFinal: Bool
    }

    @ObservationIgnored private var updates: AsyncStream<Update>.Continuation?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rawServerContent = ""
    @ObservationIgnored private var completion: (@MainActor () -> Void)?

    deinit {
        processingTask?.cancel()
        updates?.finish()
    }

    func beginStreaming(messageId: String, modelId: String?) {
        beginStreamingForContinue(messageId: messageId, modelId: modelId, existingContent: "")
    }

    func beginStreamingForContinue(messageId: String, modelId: String?, existingContent: String) {
        processingTask?.cancel()
        updates?.finish()
        completion = nil
        generation &+= 1
        let currentGeneration = generation
        streamingMessageId = messageId
        streamingModelId = modelId
        displayContent = existingContent
        frozenContent = ""
        liveTail = ""
        streamingStatusHistory = []
        streamingSources = []
        streamingError = nil
        isActive = true
        rawServerContent = existingContent
        rateMeter.reset(existingContent: existingContent)

        let pipeline = StreamingPipeline { [weak self] snapshot in
            guard let self, self.generation == currentGeneration else { return }
            self.applySnapshot(snapshot)
        }
        // Only cumulative snapshots may be superseded, never raw token deltas
        // or tool/status events. An idle consumer runs immediately; no timer.
        let (stream, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = continuation
        processingTask = Task {
            await pipeline.beginWithPrefix(existingContent)
            for await update in stream {
                guard !Task.isCancelled else { break }
                if update.isFinal {
                    await pipeline.setFinalContent(update.content)
                } else {
                    await pipeline.append(update.content)
                }
            }
        }
    }

    func updateContent(_ content: String) {
        guard let updates else { return }
        rawServerContent = content
        rateMeter.record(content)
        updates.yield(Update(content: content, isFinal: false))
    }

    /// Appends a status update.
    func appendStatus(_ status: ChatStatusUpdate) {
        if let idx = streamingStatusHistory.firstIndex(
            where: { $0.action == status.action && $0.done != true }
        ) {
            streamingStatusHistory[idx] = status
        } else {
            let isDuplicate = streamingStatusHistory.contains(where: {
                $0.action == status.action && $0.done == true && status.done == true
            })
            if !isDuplicate { streamingStatusHistory.append(status) }
        }
    }

    /// Appends source references.
    func appendSources(_ sources: [ChatSourceReference]) {
        for source in sources {
            if !streamingSources.contains(where: {
                ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
            }) {
                streamingSources.append(source)
            }
        }
    }

    /// Sets an error on the streaming message.
    func setError(_ error: ChatMessageError) {
        streamingError = error
    }

    /// The authoritative final snapshot goes through the same ordered consumer.
    @discardableResult
    func endStreaming(finalContent: String? = nil, onFinished: (@MainActor () -> Void)? = nil) -> StreamingResult {
        guard let updates else { return currentResult() }
        if let finalContent { rawServerContent = finalContent }
        let result = currentResult()
        completion = onFinished
        updates.yield(Update(content: rawServerContent, isFinal: true))
        updates.finish()
        self.updates = nil
        return result
    }

    @discardableResult
    func abortStreaming() -> StreamingResult {
        let result = currentResult()
        completeCleanup()
        return result
    }

    struct StreamingResult {
        let messageId: String?
        let content: String
        let statusHistory: [ChatStatusUpdate]
        let sources: [ChatSourceReference]
        let error: ChatMessageError?
    }

    private func currentResult() -> StreamingResult {
        StreamingResult(
            messageId: streamingMessageId, content: rawServerContent,
            statusHistory: streamingStatusHistory, sources: streamingSources, error: streamingError
        )
    }

    private func applySnapshot(_ snapshot: StreamingSnapshot) {
        guard snapshot.isActive else {
            completeCleanup()
            return
        }
        let didReveal = snapshot.displayContent.utf8.count > displayContent.utf8.count
        displayContent = snapshot.displayContent
        frozenContent = snapshot.frozenContent
        liveTail = snapshot.liveTail
        if didReveal { Haptics.streamingTick() }
    }

    private func completeCleanup() {
        generation &+= 1
        processingTask?.cancel()
        processingTask = nil
        updates?.finish()
        updates = nil
        let onFinished = completion
        completion = nil
        streamingMessageId = nil
        rawServerContent = ""
        displayContent = ""
        frozenContent = ""
        liveTail = ""
        streamingStatusHistory = []
        // Keep sources until the next session so citations survive finalization.
        streamingError = nil
        streamingModelId = nil
        isActive = false
        Haptics.streamingComplete()
        onFinished?()
    }
}
