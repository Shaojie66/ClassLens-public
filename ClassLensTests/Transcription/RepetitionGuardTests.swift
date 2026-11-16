import Testing
@testable import ClassLens

struct RepetitionGuardTests {
    @Test func collapsesRunawayPhrases() {
        let looped = "And then " + Array(repeating: "Let's see.", count: 20).joined(separator: " ")
        let result = RepetitionGuard.collapse(looped)
        #expect(result.collapsed)
        #expect(result.text == "And then Let's see.")
    }

    @Test func keepsNaturalRepetition() {
        let text = "correct, correctly classified classified examples. Very, very, very important."
        let result = RepetitionGuard.collapse(text)
        #expect(!result.collapsed)
        #expect(result.text == text)
    }
}
