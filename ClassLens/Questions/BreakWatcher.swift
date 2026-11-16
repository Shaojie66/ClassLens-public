import Foundation

/// Notices the teacher calling a break and coming back, so question spotting stops in between.
///
/// During the Week 7 break the recognizer turned classroom chatter into lecture-like lines back to back
/// ("Why? Where? Why?"), so the content can't tell a break from teaching. Only the teacher's own words can:
/// a break starts on an announcement ("three minute break now", "let's take a break") and ends on a return
/// ("All right, back", "let's continue"), or after a time limit when no return is heard. All times are
/// transcript times, so replays and evaluations behave like a live lecture.
struct BreakWatcher: Sendable {
    enum Change: Sendable, Equatable {
        case started(at: TimeInterval)
        case ended(at: TimeInterval)
    }

    /// Return phrases inside this window are part of the announcement ("be back in five minutes").
    var settling: TimeInterval = 60
    var limitWithoutLength: TimeInterval = 15 * 60
    var shortestLimit: TimeInterval = 8 * 60
    var longestLimit: TimeInterval = 20 * 60

    private(set) var startedAt: TimeInterval?
    private var announcedMinutes: Double?

    var isOnBreak: Bool { startedAt != nil }

    /// How long a break may run without a return phrase: twice what was announced (Week 7's "three minutes"
    /// took six), within the shortest and longest limits.
    var limit: TimeInterval {
        guard let announcedMinutes else { return limitWithoutLength }
        return min(longestLimit, max(shortestLimit, announcedMinutes * 60 * 2))
    }

    mutating func observe(_ segment: TranscriptSegment) -> Change? {
        let text = segment.text.lowercased()
        guard let startedAt else {
            guard Self.announcesBreak(text) else { return nil }
            startedAt = segment.start
            announcedMinutes = Self.minutes(in: text)
            return .started(at: segment.start)
        }
        let since = segment.start - startedAt
        if since <= settling {
            if announcedMinutes == nil { announcedMinutes = Self.minutes(in: text) }
            return nil
        }
        if Self.announcesReturn(text) || since >= limit {
            end()
            return .ended(at: segment.start)
        }
        return nil
    }

    /// The student turned spotting back on by hand.
    mutating func end() {
        startedAt = nil
        announcedMinutes = nil
    }

    // MARK: Phrases

    private static let breakStarts = [
        #"\bbreak (now|time)\b"#,
        #"\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty)[- ]minutes?(?: of)? (break|rest)\b"#,
        #"\b(let's|let us|we'll|we will|we can|i'll|i will|time to|time for)\b[^.?!]{0,30}\b(take|have|give|grab)\b[^.?!]{0,20}\bbreak\b(?! (down|it|the|this|that|up|into|through|even))"#,
        #"\btime for (a|our|the) (quick |short |little |coffee )?break\b"#,
        #"\b(see you|be) back in \w+ minutes\b"#,
    ]
    /// A break mentioned for later ("after the break", "we'll take a break at half past") hasn't started.
    private static let later = #"\b(after|later|before|until|halfway|half way|at the end|end of|in (a|an|\w+) (minute|minutes|hour)|at (half|quarter|\d))\b"#
    private static let returns = [
        #"\b(we're |we are |i'm |i am |all right,? |alright,? |okay,? |ok,? )back\b"#,
        #"^back\b"#,
        #"\bwelcome back\b"#,
        #"\blet's (go|start|continue|get started|resume|begin|carry on|get going)\b"#,
        #"\b(let's|we) (get|go) back to\b"#,
        #"\bwhere were we\b"#,
    ]

    static func announcesBreak(_ text: String) -> Bool {
        sentences(text).contains { sentence in
            breakStarts.contains { sentence.range(of: $0, options: .regularExpression) != nil }
                && (sentence.range(of: later, options: .regularExpression) == nil || sentence.contains("break now")
                    || sentence.range(of: #"\bback in \w+ minutes\b"#, options: .regularExpression) != nil)
        }
    }

    static func announcesReturn(_ text: String) -> Bool {
        sentences(text).contains { sentence in returns.contains { sentence.range(of: $0, options: .regularExpression) != nil } }
    }

    /// The length in "three minute break" or "back in five minutes"; other minutes ("we can finish five
    /// minutes earlier") aren't the break's.
    static func minutes(in text: String) -> Double? {
        let count = #"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty)"#
        let phrases = [#"\b"# + count + #"[- ]minutes?(?: of)? (break|rest)\b"#, #"\b(back in|for) "# + count + #" minutes?\b"#]
        guard let range = phrases.lazy.compactMap({ text.range(of: $0, options: .regularExpression) }).first else { return nil }
        let words = text[range].split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard let word = words.first(where: { Double($0) != nil || !NumberWords.values(in: [$0]).isEmpty }) else { return nil }
        return Double(word) ?? NumberWords.values(in: [word]).first.map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    private static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { ".?!".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
