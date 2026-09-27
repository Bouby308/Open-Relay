import Foundation
import Observation

/// Streams the assistant reply text for a voice-call turn.
///
/// Uses Observation tracking on `ChatViewModel` / `StreamingContentStore`
/// so updates are event-driven (no fixed-interval polling). Yields the full
/// accumulated text each time it changes; finishes when streaming ends,
/// yielding the final persisted message content last.
@MainActor
enum ResponseTextStream {

    /// - Parameters:
    ///   - knownAssistantIds: IDs of every assistant message that existed
    ///     before sending. The reply is the first assistant message NOT in
    ///     this set — an old reply is never spoken, even if the send fails.
    ///   - sendFinished: returns true once `sendMessage()` has returned.
    static func stream(
        for chat: ChatViewModel,
        knownAssistantIds: Set<String>,
        sendFinished: @escaping @MainActor () -> Bool
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                // 1. Wait for the new assistant placeholder to appear.
                var replyId: String?
                while !Task.isCancelled {
                    replyId = newReplyId(chat, known: knownAssistantIds)
                    if replyId != nil || sendFinished() { break }
                    await waitForChange(chat)
                }
                // Send failed before a reply was created (or re-check once
                // in case it appeared in the same tick the send finished).
                if replyId == nil { replyId = newReplyId(chat, known: knownAssistantIds) }
                guard let replyId, !Task.isCancelled else { continuation.finish(); return }

                // 2. Stream its content until the send is done and it's no
                //    longer the live streaming message.
                var last = ""
                while !Task.isCancelled {
                    let text = currentText(chat, replyId: replyId)
                    if text != last {
                        last = text
                        continuation.yield(text)
                    }
                    if sendFinished() && !isLive(chat, replyId: replyId) { break }
                    await waitForChange(chat)
                }
                guard !Task.isCancelled else { continuation.finish(); return }

                // 3. Final persisted content (may differ after post-processing).
                let final = persistedContent(chat, replyId: replyId)
                if let final, !final.isEmpty, final != last {
                    continuation.yield(final)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Snapshot of the current assistant IDs — call before `sendMessage`.
    static func assistantIds(in chat: ChatViewModel) -> Set<String> {
        Set(chat.messages.lazy.filter { $0.role == .assistant }.map(\.id))
    }

    private static func newReplyId(_ chat: ChatViewModel, known: Set<String>) -> String? {
        chat.messages.last(where: { $0.role == .assistant && !known.contains($0.id) })?.id
    }

    private static func isLive(_ chat: ChatViewModel, replyId: String) -> Bool {
        if chat.streamingStore.isActive && chat.streamingStore.streamingMessageId == replyId {
            return true
        }
        return chat.messages.last(where: { $0.id == replyId })?.isStreaming ?? false
    }

    private static func persistedContent(_ chat: ChatViewModel, replyId: String) -> String? {
        chat.messages.last(where: { $0.id == replyId })?.content
    }

    private static func currentText(_ chat: ChatViewModel, replyId: String) -> String {
        if chat.streamingStore.isActive, chat.streamingStore.streamingMessageId == replyId {
            return chat.streamingStore.displayContent
        }
        return persistedContent(chat, replyId: replyId) ?? ""
    }

    /// Suspends until any tracked property changes (or 500 ms safety timeout,
    /// covering socket-driven updates that bypass observation).
    private static func waitForChange(_ chat: ChatViewModel) async {
        let box = ResumeOnce()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            box.set(c)
            withObservationTracking {
                _ = chat.isStreaming
                _ = chat.streamingStore.isActive
                _ = chat.streamingStore.displayContent
                _ = chat.messages.count
                _ = chat.messages.last?.content
                _ = chat.messages.last?.isStreaming
            } onChange: {
                box.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                box.resume()
            }
        }
    }
}

/// Resumes a continuation at most once, from any thread.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func set(_ c: CheckedContinuation<Void, Never>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
