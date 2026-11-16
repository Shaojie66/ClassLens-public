import Foundation

/// Prompts for asking the fast model which slide the lecturer is on.
enum SlidePrompts {
    /// The numbered slides go in the system prompt, which stays the same all lecture and is served from
    /// the provider's prompt cache after the first call.
    static func system(outline: String) -> String {
        """
        You follow a live university lecture and decide which slide the lecturer is talking about right now. \
        Reply with a JSON object only: {"slide": 12, "confidence": 0.8}

        - The transcript comes from speech recognition and has errors; match by meaning, not exact words.
        - Lecturers usually move forward one slide at a time. Several slides may cover the same example: \
        choose the one whose specific point matches what is being said now.
        - Figures are not in the slide text. When the lecturer describes a plot (curves, colours, areas, \
        thresholds), pick the slide whose topic that plot would illustrate.
        - If the lecturer is off the slides (break, chat, live demo in another program), give the previous \
        slide with low confidence.
        - "confidence" is your probability that the slide is right, from 0 to 1.

        Slides:
        \(outline)
        """
    }

    static func user(recent: String, previous: Int?) -> String {
        let before = previous.map { "Slide about 30 seconds ago: \($0)." } ?? "Slide before this: unknown."
        return before + "\n\nTranscript of the last 90 seconds, newest last:\n" + recent
    }

    /// "[n] text" per slide, numbered from 1, each cut to `limit` characters.
    static func outline(_ slideTexts: [String], limit: Int = 320) -> String {
        slideTexts.enumerated().map { index, text in
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "[\(index + 1)] " + String(flat.prefix(limit))
        }.joined(separator: "\n")
    }
}
