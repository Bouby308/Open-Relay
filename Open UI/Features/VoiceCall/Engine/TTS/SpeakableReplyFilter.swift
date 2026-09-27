import Foundation

/// Reduces a raw (possibly still-streaming) assistant reply to only the
/// prose a listener should hear during a voice call.
///
/// - Complete blocks (`<details …>…</details>` — tool calls, reasoning,
///   code interpreter — raw reasoning tags like `<think>…</think>`,
///   fenced code and `$$…$$` math) are replaced with a line break.
/// - Incomplete blocks truncate the output at their start, so nothing
///   inside them is spoken until they close.
///
/// Because unfinished content is always cut off rather than partially
/// emitted, successive outputs for a growing input only ever grow at the
/// end — keeping `SentenceChunker`'s character offset valid.
nonisolated enum SpeakableReplyFilter {

    private static let reasoningPairs: [(open: [Character], close: [Character])] = [
        ("<|begin_of_thought|>", "<|end_of_thought|>"),
        ("◁think▷", "◁/think▷"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
        ("<thought>", "</thought>"),
        ("<reason>", "</reason>"),
        ("<think>", "</think>"),
    ].map { (Array($0.0), Array($0.1)) }

    private static let detailsOpen = Array("<details")
    private static let detailsClose = Array("</details")
    private static let fence = Array("```")
    private static let mathFence = Array("$$")

    static func filter(_ raw: String) -> String {
        guard raw.contains(where: { $0 == "<" || $0 == "`" || $0 == "$" || $0 == "◁" }) else {
            return raw
        }
        let s = Array(raw)
        var out = ""
        out.reserveCapacity(s.count)
        var i = 0

        while i < s.count {
            let c = s[i]

            // Fenced code / display math.
            if c == "`" || c == "$" {
                let delim = c == "`" ? fence : mathFence
                if matches(s, at: i, delim) {
                    guard let close = find(s, delim, from: i + delim.count) else { break }
                    out.append("\n")
                    i = close + delim.count
                    continue
                }
                // A trailing partial delimiter may still be arriving.
                if isPartialPrefix(s, at: i, of: delim) { break }
            }

            if c == "<" || c == "◁" {
                // <details …>…</details>
                if isDetailsOpen(s, at: i) {
                    guard let end = endOfDetailsBlock(s, from: i) else { break }
                    out.append("\n")
                    i = end
                    continue
                }
                // Raw reasoning tags.
                if let pair = reasoningPairs.first(where: { matches(s, at: i, $0.open) }) {
                    guard let close = find(s, pair.close, from: i + pair.open.count) else { break }
                    out.append("\n")
                    i = close + pair.close.count
                    continue
                }
                // Tag that may still be arriving (e.g. "<deta" or "<thi").
                if isPartialPrefix(s, at: i, of: detailsOpen)
                    || reasoningPairs.contains(where: { isPartialPrefix(s, at: i, of: $0.open) }) {
                    break
                }
            }

            out.append(c)
            i += 1
        }
        return out
    }
}

// MARK: - <details> scanning

private extension SpeakableReplyFilter {

    nonisolated static func isDetailsOpen(_ s: [Character], at i: Int) -> Bool {
        guard matches(s, at: i, detailsOpen) else { return false }
        let next = i + detailsOpen.count
        return next >= s.count || s[next].isWhitespace || s[next] == ">"
    }

    /// Index just past the matching `</details>`, or nil if the block (or
    /// its opening tag) is incomplete. Quote-aware inside opening tags and
    /// nesting-aware, mirroring `ToolCallParser.findDetailsBlocks`.
    nonisolated static func endOfDetailsBlock(_ s: [Character], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < s.count {
            if isDetailsOpen(s, at: i) {
                guard let tagEnd = endOfOpeningTag(s, from: i + detailsOpen.count) else { return nil }
                depth += 1
                i = tagEnd
                continue
            }
            if matches(s, at: i, detailsClose) {
                var m = i + detailsClose.count
                while m < s.count && s[m] != ">" { m += 1 }
                guard m < s.count else { return nil }
                depth -= 1
                i = m + 1
                if depth == 0 { return i }
                continue
            }
            i += 1
        }
        return nil
    }

    /// Index just past the `>` ending an opening tag, ignoring `>` inside
    /// quoted attribute values.
    nonisolated static func endOfOpeningTag(_ s: [Character], from start: Int) -> Int? {
        var quote: Character?
        var j = start
        while j < s.count {
            let ch = s[j]
            if let q = quote {
                if ch == "\\" { j += 2; continue }
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return j + 1
            }
            j += 1
        }
        return nil
    }
}


// MARK: - Matching helpers

private extension SpeakableReplyFilter {

    /// Case-insensitive match of `pattern` at `i`.
    nonisolated static func matches(_ s: [Character], at i: Int, _ pattern: [Character]) -> Bool {
        guard i + pattern.count <= s.count else { return false }
        for k in 0..<pattern.count where !equalIgnoringCase(s[i + k], pattern[k]) {
            return false
        }
        return true
    }

    /// True when the text from `i` to the end is a proper prefix of `pattern`.
    nonisolated static func isPartialPrefix(_ s: [Character], at i: Int, of pattern: [Character]) -> Bool {
        let remaining = s.count - i
        guard remaining > 0, remaining < pattern.count else { return false }
        for k in 0..<remaining where !equalIgnoringCase(s[i + k], pattern[k]) {
            return false
        }
        return true
    }

    nonisolated static func find(_ s: [Character], _ pattern: [Character], from start: Int) -> Int? {
        var i = start
        while i + pattern.count <= s.count {
            if matches(s, at: i, pattern) { return i }
            i += 1
        }
        return nil
    }

    nonisolated static func equalIgnoringCase(_ a: Character, _ b: Character) -> Bool {
        a == b || a.lowercased() == b.lowercased()
    }
}

