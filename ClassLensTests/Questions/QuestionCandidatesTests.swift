import Testing
@testable import ClassLens

struct QuestionCandidatesTests {
    @Test(arguments: [
        "So how can we formalize this hypothesis testing problem?",
        "What exactly are we testing?",
        "Why does the variance shrink as n grows",
    ])
    func findsRealQuestions(_ text: String) {
        #expect(!QuestionCandidates.candidates(in: text).isEmpty)
    }

    @Test(arguments: [
        "Right?",
        "Does that make sense?",
        "Can you hear me?",
        "That gives us the parameter of interest, right?",
        "Any questions?",
        "The mean is an unbiased estimator.",
    ])
    func skipsFillerAndStatements(_ text: String) {
        #expect(QuestionCandidates.candidates(in: text).isEmpty)
    }

    @Test func picksTheQuestionOutOfAMixedSegment() {
        let found = QuestionCandidates.candidates(in: "Let's go. What's the null hypothesis? Think about it.")
        #expect(found == ["What's the null hypothesis?"])
    }
}
