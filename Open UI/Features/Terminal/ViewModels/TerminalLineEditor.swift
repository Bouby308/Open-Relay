import Foundation
import SwiftTerm

/// Local line editing for the interactive shell (telnet/mosh-style line mode).
///
/// Printable keys are drawn locally and held; nothing is sent until Return,
/// so typing is instant regardless of network speed. Keys that need the shell
/// right away (Tab completion, history, Ctrl-keys, Esc) first flush the
/// pending text, then pass through. Full-screen apps, mouse mode and password
/// prompts are detected so the caller can switch to live (per-key) mode.
@MainActor
final class TerminalLineEditor {

    /// Characters typed but not yet sent.
    private(set) var buffer: [Character] = []
    /// Cursor position within `buffer`.
    private(set) var cursor = 0
    /// Cells the local echo occupies on screen, and cells before the cursor.
    private var echoedCells = 0
    private var cursorCells = 0

    var isEmpty: Bool { buffer.isEmpty }

    // MARK: - Mode detection

    /// True when keystrokes must reach the shell immediately.
    static func needsLiveMode(_ terminal: Terminal) -> Bool {
        if terminal.isCurrentBufferAlternate { return true }   // vim, less, top, tmux…
        if terminal.mouseMode != .off { return true }           // mouse-driven TUIs
        return looksLikeSecretPrompt(terminal)
    }

    /// Heuristic: the text left of the cursor looks like a password prompt, so
    /// typed characters must never be drawn locally.
    static func looksLikeSecretPrompt(_ terminal: Terminal) -> Bool {
        let (x, y) = terminal.getCursorLocation()
        guard x > 0, let line = terminal.getLine(row: y) else { return false }
        let prefix = line.translateToString(trimRight: true, startCol: 0, endCol: x).lowercased()
        let tail = prefix.trimmingCharacters(in: .whitespaces)
        guard let last = tail.last, [":", "?", ">", "]"].contains(last) else { return false }
        return ["password", "passphrase", "passcode", "pin:", "token:", "secret", "verification code", "otp"]
            .contains { tail.contains($0) }
    }

    // MARK: - Editing

    /// Processes one chunk of keyboard bytes and returns what must be sent now
    /// (empty when the edit was handled locally).
    func handle(_ bytes: ArraySlice<UInt8>, view: TerminalView) -> [UInt8] {
        // Text insertion (the common case): printable UTF-8 with no control bytes.
        if let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty,
           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
            redraw(view) {
                buffer.insert(contentsOf: Array(text), at: cursor)
                cursor += text.count
            }
            return []
        }

        let key = Array(bytes)
        switch key {
        case [0x0D], [0x0A], [0x0D, 0x0A]:
            // Return: erase the local echo, send the whole line + Enter at once.
            return Array(takeLine(view).utf8) + [0x0D]
        case [0x7F], [0x08]:
            guard cursor > 0 else { return key } // nothing local — let the shell handle it
            redraw(view) { buffer.remove(at: cursor - 1); cursor -= 1 }
            return []
        case [0x1B, 0x5B, 0x44], [0x1B, 0x4F, 0x44]: // ←
            guard cursor > 0 else { return flush(view) + key }
            redraw(view) { cursor -= 1 }
            return []
        case [0x1B, 0x5B, 0x43], [0x1B, 0x4F, 0x43]: // →
            guard cursor < buffer.count else { return flush(view) + key }
            redraw(view) { cursor += 1 }
            return []
        case [0x01] where !buffer.isEmpty: // Ctrl-A
            redraw(view) { cursor = 0 }; return []
        case [0x05] where !buffer.isEmpty: // Ctrl-E
            redraw(view) { cursor = buffer.count }; return []
        case [0x15] where !buffer.isEmpty: // Ctrl-U: delete to start
            redraw(view) { buffer.removeFirst(cursor); cursor = 0 }; return []
        case [0x17] where !buffer.isEmpty: // Ctrl-W: delete previous word
            redraw(view) {
                var i = cursor
                while i > 0 && buffer[i - 1] == " " { i -= 1 }
                while i > 0 && buffer[i - 1] != " " { i -= 1 }
                buffer.removeSubrange(i..<cursor); cursor = i
            }
            return []
        case [0x03]:
            // Ctrl-C: discard the unsent line and interrupt.
            erase(view)
            buffer.removeAll(); cursor = 0
            return key
        default:
            // Tab, ↑/↓, Ctrl-R, Esc, Ctrl-D, function keys… the shell needs its
            // real line state, so hand over the pending text first.
            return flush(view) + key
        }
    }

    /// Inserts pasted text locally. Returns false when it should go straight
    /// to the shell instead (multi-line pastes).
    func paste(_ text: String, view: TerminalView) -> Bool {
        guard !text.contains("\n"), !text.contains("\r"),
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\t" }) else { return false }
        let clean = text.replacingOccurrences(of: "\t", with: " ")
        redraw(view) { buffer.insert(contentsOf: Array(clean), at: cursor); cursor += clean.count }
        return true
    }

    /// Removes the local echo and returns the pending text (without Enter).
    func flush(_ view: TerminalView?) -> [UInt8] {
        guard !buffer.isEmpty else { return [] }
        return Array(takeLine(view).utf8)
    }

    /// Forgets local state without touching the screen (after a reset).
    func discard() {
        buffer.removeAll(); cursor = 0; echoedCells = 0; cursorCells = 0
    }

    // MARK: - Output interleaving

    /// Before server output is drawn: remove the echo so output lands where the
    /// shell expects it.
    func hideEcho(_ view: TerminalView) { erase(view) }

    /// After server output: redraw the pending line at the new cursor.
    func showEcho(_ view: TerminalView) {
        if echoedCells == 0 { draw(view) }
    }

    // MARK: - Drawing

    private func takeLine(_ view: TerminalView?) -> String {
        if let view { erase(view) }
        let line = String(buffer)
        buffer.removeAll(); cursor = 0
        return line
    }

    private func redraw(_ view: TerminalView, _ mutate: () -> Void) {
        erase(view)
        mutate()
        draw(view)
    }

    /// Cursor-movement sequence that moves `cells` cells left, crossing
    /// wrapped rows, from the current cursor position.
    private func moveLeft(_ cells: Int, _ view: TerminalView) -> String {
        guard cells > 0 else { return "" }
        let terminal = view.getTerminal()
        let cols = max(1, terminal.cols)
        let x = min(terminal.getCursorLocation().x, cols - 1)
        let target = x - cells
        if target >= 0 { return "\u{1B}[\(cells)D" }
        let rowsUp = (-target + cols - 1) / cols
        let col = target + rowsUp * cols
        return "\u{1B}[\(rowsUp)A\r" + (col > 0 ? "\u{1B}[\(col)C" : "")
    }

    private func erase(_ view: TerminalView) {
        guard echoedCells > 0 else { return }
        view.feed(text: moveLeft(cursorCells, view) + "\u{1B}[J")
        echoedCells = 0
        cursorCells = 0
    }

    private func draw(_ view: TerminalView) {
        guard !buffer.isEmpty else { return }
        let full = String(buffer)
        view.feed(text: full)
        echoedCells = Self.cellWidth(full)
        cursorCells = echoedCells
        let back = Self.cellWidth(String(buffer[cursor...]))
        if back > 0 {
            view.feed(text: moveLeft(back, view))
            cursorCells = echoedCells - back
        }
    }

    /// Terminal cell width (wide CJK characters and emoji take 2 cells).
    static func cellWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { width, scalar in
            let v = scalar.value
            if v < 0x20 || (0x300...0x36F).contains(v) || v == 0x200D || (0xFE00...0xFE0F).contains(v) { return width }
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
            return width + (wide ? 2 : 1)
        }
    }
}
