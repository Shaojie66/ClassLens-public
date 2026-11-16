import Testing
@testable import ClassLens

struct SlideLocatorTests {
    @Test func parsesAndBoundsTheAnswer() {
        #expect(SlideLocator.parse(#"{"slide": 22, "confidence": 0.8}"#, slideCount: 26) == .init(slide: 21, confidence: 0.8))
        #expect(SlideLocator.parse(#"{"slide": 3}"#, slideCount: 26) == .init(slide: 2, confidence: 0.5))
        #expect(SlideLocator.parse(#"{"slide": 27, "confidence": 0.9}"#, slideCount: 26) == nil)
        #expect(SlideLocator.parse("no idea", slideCount: 26) == nil)
        #expect(SlideLocator.parse(#"{"slide": 2, "confidence": 3}"#, slideCount: 26)?.confidence == 1)
    }

    @Test func outlineNumbersSlidesFromOne() {
        let outline = SlidePrompts.outline(["Title  slide", "Type II errors\n β = P(fail to reject H0)"])
        #expect(outline == "[1] Title slide\n[2] Type II errors β = P(fail to reject H0)")
    }

    @Test func hintOutweighsWeakWordOverlap() {
        let pages = ["Introduction", "Null hypothesis H0", "Type II errors, beta, power"]
        var tracker = SlideTracker(pageTexts: pages)
        for _ in 0..<2 {
            tracker.update(recentTranscript: "so this green curve here, under the red lines", hint: .init(slide: 2, confidence: 0.9))
        }
        #expect(tracker.shown?.slide == 2)
    }
}
