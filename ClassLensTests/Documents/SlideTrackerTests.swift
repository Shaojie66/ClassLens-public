import Testing
@testable import ClassLens

struct SlideTrackerTests {
    private let pages = [
        "Introduction to Statistical Inference",
        "Null hypothesis 𝐻0: 𝜃 = 𝜃0 and the alternative hypothesis 𝐻1",
        "One-sample t-test: test statistic t0, degrees of freedom, critical region",
        "P-values: probability of a result at least as extreme under 𝐻0",
        "Type-I error: false positive, significance level α",
        "Type II errors: β, power of the test, effect size, sample size",
    ]

    @Test func unifiesNotationAcrossSlidesAndSpeech() {
        #expect(SlideTracker.tokens("Null hypothesis 𝐻0: 𝜃 = 𝜃0").contains("h0"))
        #expect(SlideTracker.tokens("we write H zero, the null").contains("h0"))
        #expect(SlideTracker.tokens("𝜃 and theta").filter { $0 == "theta" }.count == 2)
        #expect(SlideTracker.tokens("Type-I error").contains("type1"))
        #expect(SlideTracker.tokens("type one errors").contains("type1"))
        #expect(SlideTracker.tokens("the p-values").contains("pvalue"))
    }

    @Test func followsALectureThroughTheSlides() {
        var tracker = SlideTracker(pageTexts: pages)
        #expect(tracker.shown == nil)
        let talk = [
            (3, "so the t statistic t zero, with n minus one degrees of freedom, and the critical region"),
            (3, "we compare t zero with the critical value for these degrees of freedom"),
            (5, "now type two errors, beta, and the power of the test, which depends on effect size and sample size"),
            (5, "the larger the sample size the higher the power"),
        ]
        var visited: [Int] = []
        for (_, sentence) in talk {
            tracker.update(recentTranscript: sentence)
            visited.append(tracker.estimate.page)
        }
        #expect(visited.first == 2)
        #expect(visited.last == 5)
        #expect(tracker.followedPage == 5)
        #expect(tracker.slideCount == pages.count)
    }

    @Test func groupsAnimationBuildsIntoOneSlide() {
        let deck = [
            "Title slide",
            "Example | Suppose we test whether students guess weight",
            "Example | Suppose we test whether students guess weight | Sample mean 79.5",
            "Example | Suppose we test whether students guess weight | Sample mean 79.5 | t0 = 2.1",
            "P-values | probability of a result as extreme",
        ]
        var tracker = SlideTracker(pageTexts: deck)
        #expect(tracker.slides == [0...0, 1...3, 4...4])
        tracker.update(recentTranscript: "students guess the weight, the sample mean is 79.5 and t zero is 2.1")
        #expect(tracker.estimate.slide == 1)
        // Shows the fully built page of the slide.
        #expect(tracker.estimate.page == 3)
        #expect(tracker.slide(containing: 2) == 1)
    }

    @Test func answerContextCoversNeighbours() {
        var tracker = SlideTracker(pageTexts: pages)
        for _ in 0..<3 { tracker.update(recentTranscript: "p values, the probability of a result at least as extreme under H zero") }
        #expect(tracker.shown?.slide == 3)
        let context = tracker.context { pages[$0] }
        #expect(context.contains("[第 3 页]"))
        #expect(context.contains("[第 4 页（最可能是这一页）]"))
        #expect(context.contains("[第 5 页]"))
        #expect(!context.contains("[第 6 页]"))
    }

    @Test func oneConfidentStepDoesNotTurnThePage() {
        var tracker = SlideTracker(pageTexts: pages)
        for _ in 0..<2 { tracker.update(recentTranscript: "the t statistic t zero, degrees of freedom, critical region") }
        #expect(tracker.shown?.slide == 2)
        tracker.update(recentTranscript: "type two errors beta power effect size sample size")
        // The estimate may move at once, but the shown slide waits for a second confirmation.
        #expect(tracker.shown?.slide == 2)
        tracker.update(recentTranscript: "power of the test, effect size and sample size")
        #expect(tracker.shown?.slide == 5)
    }

    @Test func findsTheSlideWhenRecordingStartsMidLecture() {
        var tracker = SlideTracker(pageTexts: pages)
        for _ in 0..<3 { tracker.update(recentTranscript: "type two errors, beta, the power of the test, effect size and sample size") }
        #expect(tracker.shown?.slide == 5)
    }

    @Test func smallTalkKeepsThePage() {
        var tracker = SlideTracker(pageTexts: pages)
        tracker.update(recentTranscript: "type two errors beta power effect size sample size")
        tracker.update(recentTranscript: "power of the test and sample size")
        let page = tracker.estimate.page
        tracker.update(recentTranscript: "okay can everyone hear me at the back, good, thank you")
        #expect(tracker.estimate.page == page)
    }
}
