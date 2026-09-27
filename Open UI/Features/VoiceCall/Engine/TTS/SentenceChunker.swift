import Foundation

/// Splits streaming LLM text into speakable sentences as it arrives.
///
/// Feed the full accumulated reply text each time with `feed(_:)`; it
/// returns only newly completed sentences (cleaned for speech).
/// Call `flush(_:)` once the reply finishes to get the remaining tail.
struct SentenceChunker {

    /// Raw-text character count already emitted.
    private(set) var consumedLength = 0

    mutating func reset() { consumedLength = 0 }

    mutating func feed(_ fullText: String) -> [String] {
        // The final persisted text can be slightly shorter than the streamed
        // text; clamp rather than restart so nothing is spoken twice.
        clamp(to: fullText)
        let result = TTSTextPreprocessor.extractNewSpeakableChunks(
            from: fullText, alreadySpokenLength: consumedLength
        )
        consumedLength = result.newSpokenLength
        return result.chunks.filter(Self.isSpeakable)
    }

    mutating func flush(_ fullText: String) -> [String] {
        clamp(to: fullText)
        let result = TTSTextPreprocessor.extractFinalChunks(
            from: fullText, alreadySpokenLength: consumedLength
        )
        consumedLength = result.newSpokenLength
        return result.chunks.filter(Self.isSpeakable)
    }

    private mutating func clamp(to fullText: String) {
        let count = fullText.count
        if count < consumedLength { consumedLength = count }
    }

    /// True if the string contains at least one letter or digit.
    nonisolated static func isSpeakable(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
