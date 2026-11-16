import Testing
@testable import ClassLens

struct LigatureRepairTests {
    @Test(arguments: [
        ("Test Sta:s:c", "Test Statistic"),
        ("a t distribuTon with n − 1 degrees", "a t distribution with n − 1 degrees"),
        ("Significance level α, criTcal value, rejecTon region", "Significance level α, critical value, rejection region"),
        ("Example: guessing", "Example: guessing"),
        ("key:value and JavaTest", "key:value and JavaTest"),
        ("H0: θ = θ0", "H0: θ = θ0"),
    ])
    func repairsOnlyRealWords(damaged: String, expected: String) {
        #expect(LigatureRepair.repair(damaged) == expected)
    }

    @Test func usesTheDocumentsOwnTerms() {
        // "quantile" may be missing from the word list; the document spells it right elsewhere.
        #expect(LigatureRepair.repair("upper quanTle", knownWords: ["quantile"]) == "upper quantile")
    }
}
