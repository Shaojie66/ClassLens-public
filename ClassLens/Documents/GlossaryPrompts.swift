import Foundation

enum GlossaryPrompts {
    static let system = """
    You read the text of university lecture slides (computer science, statistics, data science) and list the \
    technical terms a Chinese student needs while following the lecture live. Reply with a JSON object only:
    {"terms": [{"en": "null hypothesis", "zh": "原假设"}]}

    Include: technical terms and multi-word concepts, notation as written (H0, θ, α, t0), acronyms, named \
    methods, algorithms and tests. Use the term's base form ("type I error", not "type I errors").
    "zh": the standard term used in Chinese university textbooks; for notation and code identifiers repeat \
    the English.
    Leave out everyday words, slide furniture (course codes, page numbers) and people's names. At most 80 terms, \
    most important first.
    """

    static func user(_ text: String) -> String {
        "Slides:\n" + text
    }
}
