import Foundation

/// Recognizers given a context prompt sometimes repeat it instead of transcribing, mostly on short,
/// near-silent audio: a 0.8 s cough came back as the whole "Technical terms in this lecture: …" list.
enum ContextEcho {
    static let lead = "Technical terms in this lecture:"

    static func context(for terms: [String]) -> String {
        terms.isEmpty ? "" : lead + " " + terms.joined(separator: ", ")
    }

    /// True when `text` repeats the context rather than transcribing speech: it contains the lead phrase,
    /// or four or more of the terms as a comma-separated run.
    static func isEcho(_ text: String, terms: [String]) -> Bool {
        let folded = text.lowercased()
        if folded.contains(lead.lowercased().dropLast()) { return true }
        let listed = Set(terms.map { $0.lowercased() })
        var run = 0
        var longest = 0
        for piece in folded.split(separator: ",") {
            let item = piece.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            run = listed.contains(item) ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest >= 4
    }
}
