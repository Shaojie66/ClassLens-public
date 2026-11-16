import Foundation

/// Collapses runaway repetition, the failure mode where a recognizer emits the same phrase over and over.
enum RepetitionGuard {
    /// Runs longer than this many copies of the same 1–8 word phrase are cut to one copy.
    static let maximumRepeats = 3

    /// Returns the cleaned text and whether anything was removed.
    static func collapse(_ text: String) -> (text: String, collapsed: Bool) {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var collapsed = false
        for size in 1...8 {
            var index = 0
            while index + size * (maximumRepeats + 1) <= words.count {
                let phrase = words[index..<index + size].map(normalized)
                var copies = 1
                while index + size * (copies + 1) <= words.count,
                      words[(index + size * copies)..<(index + size * (copies + 1))].map(normalized) == phrase {
                    copies += 1
                }
                if copies > maximumRepeats {
                    words.removeSubrange((index + size)..<(index + size * copies))
                    collapsed = true
                }
                index += 1
            }
        }
        return (words.joined(separator: " "), collapsed)
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
