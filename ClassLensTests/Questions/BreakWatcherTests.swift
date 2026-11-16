import Foundation
import Testing
@testable import ClassLens

struct BreakWatcherTests {
    private func segment(_ text: String, at start: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 5, text: text, isFinal: true)
    }

    /// The Week 7 break, line for line where it matters.
    @Test func week7BreakStartsOnTheAnnouncementAndEndsOnBack() {
        var watcher = BreakWatcher()
        #expect(watcher.observe(segment("So now, in my little watch here, is ten minutes past twelve, and I didn't nominate a volunteer to remind me of giving you all a break.", at: 3803)) == nil)
        #expect(watcher.observe(segment("Unless you want me to keep going, if I keep going, we can finish five minutes earlier. If I give her one a break now.", at: 3818.1)) == .started(at: 3818.1))
        #expect(watcher.observe(segment("I'll give you everyone three minute break now. So it's literally three minutes.", at: 3838.8)) == nil)
        #expect(watcher.limit == 8 * 60)
        #expect(watcher.observe(segment("Why? Where? Why? Where? Why?", at: 4127.5)) == nil)
        #expect(watcher.observe(segment("All right, folks. Let's go. Let's go. That was more than three minutes. All right, back. Back.", at: 4209.1)) == .ended(at: 4209.1))
        #expect(!watcher.isOnBreak)
    }

    @Test func breaksMentionedForLaterOrOtherBreaksDontStartOne() {
        for text in [
            "We'll take a break after this example.",
            "Let's break the problem down into two parts.",
            "I'll give you a break at half past.",
            "This is where the model starts to break down.",
            "Before the break we saw the t test.",
        ] {
            #expect(!BreakWatcher.announcesBreak(text.lowercased()), "\(text)")
        }
        for text in ["Let's take a five minute break.", "OK, ten-minute break.", "Time for a quick break.", "See you back in ten minutes."] {
            #expect(BreakWatcher.announcesBreak(text.lowercased()), "\(text)")
        }
    }

    @Test func returnWordsInTheAnnouncementDontEndIt() {
        var watcher = BreakWatcher()
        #expect(watcher.observe(segment("Let's take a five minute break.", at: 100)) == .started(at: 100))
        #expect(watcher.observe(segment("Be back at ten past, okay, back in five minutes.", at: 110)) == nil)
        #expect(watcher.isOnBreak)
        #expect(watcher.observe(segment("Welcome back, everyone.", at: 420)) == .ended(at: 420))
    }

    @Test func endsAfterTheLimitWithoutAReturnPhrase() {
        var watcher = BreakWatcher()
        _ = watcher.observe(segment("Ten minute break now.", at: 0))
        #expect(watcher.limit == 20 * 60)
        #expect(watcher.observe(segment("Some chatter.", at: 1100)) == nil)
        #expect(watcher.observe(segment("So the variance of the estimator…", at: 1201)) == .ended(at: 1201))

        var unannounced = BreakWatcher()
        _ = unannounced.observe(segment("Let's have a break.", at: 0))
        #expect(unannounced.limit == 15 * 60)
    }
}
