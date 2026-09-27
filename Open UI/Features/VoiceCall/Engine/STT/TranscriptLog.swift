import Foundation

/// Rolling transcript for a continuous recogniser (iOS 26 `SpeechTranscriber`).
///
/// The recogniser reports results as attributed text split into small runs
/// that are often *sub-word* pieces or bare punctuation, each with its own
/// audio time range: `["San"][" Fran"]["cisco"][","][" don"]["’t"]`. The run
/// text already contains Apple's own spacing, so the transcript must be
/// rebuilt by **concatenating runs verbatim** — splitting runs on spaces and
/// re-joining with spaces is what produced "Fran cisco , don ’t".
///
/// Final results replace everything they overlap (including the tentative
/// "volatile" guess for that audio); a new volatile result replaces the
/// previous one. Pure logic, unit-testable.
nonisolated struct TranscriptLog {

    /// One recogniser run: verbatim text + where it sits in the audio.
    struct Piece: Equatable {
        let text: String
        let start: Date
        let end: Date
    }

    /// One recogniser result (a phrase), kept as its original runs.
    struct Segment: Equatable {
        let pieces: [Piece]
        let start: Date
        let end: Date
        let isFinal: Bool
    }

    static let memory: TimeInterval = 90

    private(set) var finals: [Segment] = []
    private(set) var volatile: Segment?

    mutating func ingest(_ segment: Segment) {
        if segment.isFinal {
            // A final result is authoritative for its audio range.
            finals.removeAll { $0.start < segment.end && $0.end > segment.start }
            finals.append(segment)
            finals.sort { $0.start < $1.start }
            if let v = volatile, v.start < segment.end { volatile = nil }
            let horizon = segment.end.addingTimeInterval(-Self.memory)
            finals.removeAll { $0.end < horizon }
        } else {
            volatile = segment
        }
    }

    mutating func clear() {
        finals = []
        volatile = nil
    }

    private var segments: [Segment] {
        guard let volatile else { return finals }
        return finals.filter { $0.end <= volatile.start || $0.start >= volatile.end } + [volatile]
    }

    /// Transcript of speech from `date` on. Built from whole words (the
    /// recogniser's runs concatenated verbatim, then split at real spaces),
    /// so spelling and punctuation are exactly Apple's.
    func text(from date: Date) -> String {
        words(from: date).map(\.text).joined(separator: " ")
    }

    /// Whole words that were still being spoken at or after `date`.
    ///
    /// Filtering is by word **end**, after runs are glued into words: volatile
    /// results often carry no per-run time range, so every run inherits the
    /// whole phrase's range — filtering by run start then dropped every word
    /// of a phrase that began before the user did (e.g. during the AI's
    /// speech), and barge-in never saw the user's words.
    func words(from date: Date) -> [TimedWord] {
        segments.flatMap { seg in
            Self.words(from: seg.pieces, isFinal: seg.isFinal).filter { $0.end > date }
        }
    }

    /// Concatenates runs and splits at real whitespace; each word spans the
    /// time of the runs it was built from.
    static func words(from pieces: [Piece], isFinal: Bool) -> [TimedWord] {
        var out: [TimedWord] = []
        var text = ""
        var start: Date?
        var end: Date?
        func flush() {
            if !text.isEmpty, let s = start, let e = end {
                out.append(TimedWord(text: text, start: s, end: e, isFinal: isFinal))
            }
            text = ""; start = nil; end = nil
        }
        for piece in pieces {
            for ch in piece.text {
                if ch.isWhitespace {
                    flush()
                } else {
                    if start == nil { start = piece.start }
                    end = piece.end
                    text.append(ch)
                }
            }
        }
        flush()
        return out
    }
}
