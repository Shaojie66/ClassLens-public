import Foundation

/// Repairs text from PDFs whose font maps the "ti" ligature to a wrong character, as PowerPoint's PDF
/// export does with Calibri: "Statistic" comes out as "Sta:s:c" and "critical" as "criTcal".
///
/// A word is only changed when the repaired spelling is a real word: in the system word list, or used
/// elsewhere in the same document. "key:value" or "JavaTest" are left alone.
enum LigatureRepair {
    private static let dictionary: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// Words in `text` that show no sign of the damage, to recognize terms the word list lacks.
    static func vocabulary(of text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }.filter { $0.count > 3 })
    }

    static func repair(_ text: String, knownWords: Set<String> = []) -> String {
        guard text.contains(":") || text.contains("T") else { return text }
        var result = ""
        var word = ""
        func flush() {
            result += fixed(word, knownWords: knownWords)
            word = ""
        }
        for character in text {
            if character.isLetter || character == ":" {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    private static func fixed(_ word: String, knownWords: Set<String>) -> String {
        // A trailing colon is punctuation ("Example:"), not a ligature.
        var core = word
        var trailing = ""
        while core.last == ":" {
            core.removeLast()
            trailing.append(":")
        }
        let characters = Array(core)
        guard characters.count >= 3 else { return word }
        var candidate = ""
        var changed = false
        for (index, character) in characters.enumerated() {
            let before = index > 0 ? characters[index - 1] : nil
            let after = index + 1 < characters.count ? characters[index + 1] : nil
            let betweenLetters = (before?.isLetter ?? false) && (after?.isLetter ?? false)
            let betweenLowercase = (before?.isLowercase ?? false) && (after?.isLowercase ?? false)
            if (character == ":" && betweenLetters) || (character == "T" && betweenLowercase) {
                candidate += "ti"
                changed = true
            } else {
                candidate.append(character)
            }
        }
        guard changed, isWord(candidate.lowercased(), knownWords: knownWords) else { return word }
        return candidate + trailing
    }

    private static func isWord(_ word: String, knownWords: Set<String>) -> Bool {
        var forms = [word]
        for suffix in ["s", "es", "ly", "al", "ally"] where word.hasSuffix(suffix) {
            forms.append(String(word.dropLast(suffix.count)))
        }
        return forms.contains { dictionary.contains($0) || knownWords.contains($0) }
    }
}
