import Testing
@testable import ClassLens

struct ContextEchoTests {
    private let terms = ["null hypothesis", "rejection region", "degrees of freedom", "t distribution", "type I error", "H0"]

    @Test func catchesTheEchoedPrompt() {
        #expect(ContextEcho.isEcho("Technical terms in this lecture: null hypothesis, rejection region", terms: terms))
        #expect(ContextEcho.isEcho("rejection region, degrees of freedom, t distribution, type I error,", terms: terms))
    }

    @Test func keepsRealSpeechThatUsesTheTerms() {
        #expect(!ContextEcho.isEcho("Under H0, the statistic follows a t distribution with n minus one degrees of freedom.", terms: terms))
        #expect(!ContextEcho.isEcho("H0, H1, and the rejection region.", terms: terms))
    }

    @Test func buildsContext() {
        #expect(ContextEcho.context(for: []) == "")
        #expect(ContextEcho.context(for: ["H0", "θ"]) == "Technical terms in this lecture: H0, θ")
    }
}
