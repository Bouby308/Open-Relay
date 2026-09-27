import Foundation

/// Separates the user's words from the AI hearing itself.
///
/// Echo cancellation always leaves some residue and a recogniser will
/// transcribe it — often slightly wrong ("weather" → "whether"). The one
/// thing the call knows for certain is what it played and when, so:
///
/// - **With word timings** (iOS 26 `SpeechTranscriber`): a heard word is echo
///   if a similar word of the AI's was audible around the same moment.
///   Timing makes common words ("the", "what") safe — they only count as echo
///   when the AI said them *right then*.
/// - **Without timings** (plain transcript): echo is recognised as runs of
///   ≥ 2 consecutive words matching the AI's recent sentences in order. A
///   single shared word never counts as echo.
///
/// The output is how many **novel** words the user said. Language-neutral:
/// Unicode-folded tokens, per-character for scripts written without spaces.
nonisolated enum EchoMatcher {

    struct Verdict: Equatable {
        /// Heard tokens explained by the AI's own speech.
        let echoTokens: Int
        /// Heard tokens the AI did not say (the user's words).
        let novelTokens: Int
        var totalTokens: Int { echoTokens + novelTokens }
        /// The whole transcript is (almost) only the AI's words.
        var isEcho: Bool {
            totalTokens > 0 && novelTokens <= Int(Double(totalTokens) * EchoMatcher.mishearAllowance)
                && echoTokens > 0
        }
    }

    /// A word the AI played, positioned on the "heard" clock.
    struct SpokenWord: Equatable {
        let token: String
        let start: Date
        let end: Date
    }

    /// Echo words may be recognised a little before/after the AI played them
    /// (recogniser timing jitter + estimate error of word positions).
    static let timingSlack: TimeInterval = 0.6
    /// Share of a long transcript allowed to be misheard echo.
    static let mishearAllowance = 0.25

    // MARK: Timed (continuous engines)

    static func evaluate(heard: [TimedWord], spoken: [SpokenWord]) -> Verdict {
        var echo = 0, novel = 0
        for word in heard {
            let toks = tokens(word.text)
            guard !toks.isEmpty else { continue }
            let from = word.start.addingTimeInterval(-timingSlack)
            let to = word.end.addingTimeInterval(timingSlack)
            let nearby = spoken.filter { $0.end >= from && $0.start <= to }
            for t in toks {
                if nearby.contains(where: { similar($0.token, t) }) { echo += 1 } else { novel += 1 }
            }
        }
        return Verdict(echoTokens: echo, novelTokens: novel)
    }

    // MARK: Untimed (transcript only)

    static func evaluate(transcript: String, against spoken: [String]) -> Verdict {
        let heard = tokens(transcript)
        guard !heard.isEmpty else { return Verdict(echoTokens: 0, novelTokens: 0) }
        let reference = spoken.flatMap(tokens)
        guard !reference.isEmpty else { return Verdict(echoTokens: 0, novelTokens: heard.count) }
        var isEcho = [Bool](repeating: false, count: heard.count)
        // Mark every heard position covered by a run of ≥ 2 consecutive
        // tokens (fuzzy) that also appears consecutively in the reference.
        for i in heard.indices {
            for j in reference.indices {
                var k = 0
                while i + k < heard.count, j + k < reference.count,
                      similar(heard[i + k], reference[j + k]) { k += 1 }
                if k >= 2 { for m in i..<(i + k) { isEcho[m] = true } }
            }
        }
        // A whole transcript that is a single token matching the AI (e.g. the
        // AI said "Okay." and the mic heard "okay") is echo too.
        if heard.count == 1, reference.contains(where: { similar($0, heard[0]) }) { isEcho[0] = true }
        let echo = isEcho.filter { $0 }.count
        return Verdict(echoTokens: echo, novelTokens: heard.count - echo)
    }
}

// MARK: - Tokens & similarity

nonisolated extension EchoMatcher {

    /// Case/diacritic/width-folded tokens. Letters and digits form words;
    /// scripts written without spaces are split into single characters so
    /// matching still works for Chinese, Japanese, Thai, etc.
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: nil)
        var result: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { result.append(word); word = "" }
        }
        for scalar in folded.unicodeScalars {
            if isUnspacedScript(scalar) {
                flush()
                result.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static func isUnspacedScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x0E00...0x0E7F,   // Thai
             0x0E80...0x0EFF,   // Lao
             0x1000...0x109F,   // Myanmar
             0x1780...0x17FF:   // Khmer
            return true
        default:
            return false
        }
    }

    /// Same token, or a near-homophone the recogniser produced from echo
    /// ("weather"/"whether", "there"/"their"): edit distance ≤ 1 for short
    /// tokens, ≤ 2 for tokens of 6+ characters. Single characters must match.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        guard min(x.count, y.count) >= 2 else { return false }
        let limit = longest >= 6 ? 2 : 1
        guard abs(x.count - y.count) <= limit else { return false }
        return editDistance(x, y, limit: limit) <= limit
    }

    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var prev = Array(0...b.count)
        var curr = prev
        for i in 1...a.count {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    /// Spreads a played sentence's tokens across its audible span in
    /// proportion to their length — an estimate of when each word was heard.
    static func spokenWords(text: String, from start: Date, to end: Date) -> [SpokenWord] {
        let toks = tokens(text)
        guard !toks.isEmpty, end > start else { return [] }
        let weights = toks.map { Double(max($0.count, 1)) + 1 }   // +1 ≈ inter-word gap
        let total = weights.reduce(0, +)
        let span = end.timeIntervalSince(start)
        var t = start
        var out: [SpokenWord] = []
        for (tok, w) in zip(toks, weights) {
            let dur = span * w / total
            out.append(SpokenWord(token: tok, start: t, end: t.addingTimeInterval(dur)))
            t = t.addingTimeInterval(dur)
        }
        return out
    }
}

