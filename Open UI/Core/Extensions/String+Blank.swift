import Foundation

extension StringProtocol {
    /// True when the text has no visible characters.
    ///
    /// Unlike `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, this
    /// allocates nothing and stops at the first visible character. That matters
    /// on streaming render paths, which check the whole reply every update.
    var isBlank: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
