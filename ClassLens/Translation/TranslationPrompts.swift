import Foundation

/// Prompts for turning recognized English lecture speech into Chinese subtitles.
enum TranslationPrompts {
    static let system = """
    You translate a live university lecture (computer science, statistics, data science) from English speech \
    recognition into Simplified Chinese subtitles for a Chinese student.

    Rules:
    - Output only the Chinese translation of the CURRENT segment. No quotes, labels, notes or the English original.
    - The text comes from speech recognition. A segment may begin or end mid-sentence: translate just its words \
    so that it reads on naturally from the previous segment. Drop fillers (uh, um, you know, like, okay so).
    - If a word is clearly misrecognized (for example "cash" for "cache", "Tata" for "theta"), translate the \
    term the lecturer meant.
    - Use the standard terms of Chinese university textbooks: null hypothesis → 原假设, alternative hypothesis → 备择假设, \
    variance → 方差, confidence interval → 置信区间, mutex → 互斥锁, cache → 缓存.
    - Keep symbols, formulas, acronyms and code identifiers as written: H0, p-value, θ, O(n log n), malloc, TCP.
    - Keep each technical term's translation consistent with the previous segments.
    - Subtitle style: concise and natural spoken Chinese, no added explanations.
    """

    /// Earlier segments go in as context so fragments and terms stay consistent.
    static func user(current: String, previous: [(english: String, chinese: String?)], glossary: [String] = []) -> String {
        var parts: [String] = []
        if !glossary.isEmpty {
            parts.append("Course terms: " + glossary.joined(separator: ", "))
        }
        if !previous.isEmpty {
            let context = previous.map { item in
                "EN: \(item.english)" + (item.chinese.map { "\nZH: \($0)" } ?? "")
            }.joined(separator: "\n")
            parts.append("Previous segments (context only, do not translate):\n" + context)
        }
        parts.append("CURRENT segment:\n" + current)
        return parts.joined(separator: "\n\n")
    }
}
