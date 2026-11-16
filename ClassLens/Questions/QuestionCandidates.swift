import Foundation

/// The cheap first pass: sentences that look like questions and aren't classroom filler.
/// Most of a lecture asks nothing, so the model is only called when this finds something.
///
/// Filler list and rules adapted from Nomi (MIT), Sources/LectureNoteApp/Models/MeetingQA.swift.
enum QuestionCandidates {
    private static let questionStarts = [
        "what", "why", "how", "which", "who", "whom", "whose", "when", "where", "can", "could", "would", "should",
        "do", "does", "did", "is", "are", "was", "were", "will", "have", "has",
    ]

    /// Tag questions, check-ins and logistics: they end in a question mark but ask nothing worth answering.
    private static let fillerPhrases = [
        "right", "okay", "ok", "yeah", "yes", "huh", "eh", "you know", "isn't it", "aren't they", "don't you",
        "won't it", "got it", "make sense", "makes sense", "can you hear me", "can everyone hear", "can you see my screen",
        "can you see this", "any questions", "does that make sense", "is that clear", "are we good", "everybody ready",
        "are you ready", "shall we start", "where was i", "all right", "alright",
    ]

    /// Sentences of `text` that read like real questions.
    static func candidates(in text: String) -> [String] {
        sentences(in: text).filter { sentence in
            let folded = sentence.lowercased()
            let marked = folded.hasSuffix("?")
            // Recognizers sometimes drop the question mark, so a leading question word also counts.
            let firstWord = folded.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
            let opened = questionStarts.contains(firstWord) && folded.split(separator: " ").count >= 4
            return (marked || opened) && !isFiller(sentence)
        }
    }

    static func isFiller(_ text: String) -> Bool {
        let bare = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = bare.split(whereSeparator: \.isWhitespace)
        // "Right?" / "Okay?" — too short to ask anything.
        if words.count <= 2 { return true }
        return fillerPhrases.contains { phrase in
            // A statement ending in a tag ("…, right?") asks nothing, however long it is.
            bare.hasSuffix(", " + phrase) || bare == phrase
                || (bare.hasPrefix(phrase) && bare.count <= phrase.count + 12)
                || (bare.hasSuffix(phrase) && bare.count <= phrase.count + 12)
        }
    }

    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "?!.;".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 1 { result.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }
}
