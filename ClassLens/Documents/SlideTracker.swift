import Foundation

/// Estimates which slide the teacher is on from what they said in the last minute or so.
///
/// Slides with animated builds export as runs of near-identical pages (one per build step), which no
/// transcript can tell apart. Consecutive pages whose text is mostly contained in the next are grouped
/// into one slide; tracking works on slides and shows the last, fully built page of each.
///
/// Each slide is a TF-IDF vector of its words; the recent transcript is compared with every slide. Word
/// overlap alone jumps between similar slides, so it is combined with how lectures move (mostly stay,
/// sometimes one to three slides on, rarely back) as a hidden Markov model filtered forward in time.
struct SlideTracker: Sendable {
    struct Configuration: Sendable {
        /// Transcript considered at each step, in seconds.
        var window: TimeInterval = 75
        /// Probability of staying on the page between two steps (a step is one final segment, ~6 s).
        var stay = 0.88
        /// Moving one, two, three pages on.
        var forward = [0.08, 0.02, 0.006]
        /// Moving one page back.
        var back = 0.01
        /// Total probability of jumping to any other slide; kept tiny because examples recur across a deck.
        var jump = 0.0005
        /// How sharply similarity separates pages; smaller is more decisive. Overlapping windows reuse the
        /// same words step after step, so this also damps evidence that is counted more than once.
        var temperature = 0.15
        /// The reader follows only when the best page is at least this likely…
        var followThreshold = 0.5
        /// …for this many steps in a row, so it doesn't flicker between neighbours.
        var confirmations = 2
        /// How much the model's answer (`SlideLocator`) counts against word overlap.
        var hintWeight = 20.0

        /// Overrides from `key=value` pairs, for tuning runs: window, stay, back, jump, temperature,
        /// followThreshold, confirmations.
        mutating func apply(_ settings: String) {
            for pair in settings.split(whereSeparator: { $0 == " " || $0 == "," }) {
                let parts = pair.split(separator: "=")
                guard parts.count == 2, let value = Double(parts[1]) else { continue }
                switch parts[0] {
                case "window": window = value
                case "stay": stay = value
                case "back": back = value
                case "jump": jump = value
                case "temperature": temperature = value
                case "followThreshold": followThreshold = value
                case "confirmations": confirmations = Int(value)
                case "hintWeight": hintWeight = value
                default: continue
                }
            }
        }
    }

    struct Estimate: Equatable, Sendable {
        /// 0-based index of the slide (group of build pages).
        var slide: Int
        /// 0-based pages of that slide; `page` is the last, fully built one.
        var pages: ClosedRange<Int>
        var probability: Double

        var page: Int { pages.upperBound }
    }

    let configuration: Configuration
    /// Page ranges of each slide.
    let slides: [ClosedRange<Int>]
    private let pages: [[String: Double]]
    private let idf: [String: Double]
    private(set) var belief: [Double]

    init(pageTexts: [String], configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let slides = Self.groupBuilds(pageTexts.map(Self.tokens))
        self.slides = slides
        // A slide's text is its last page, which contains every build step before it.
        let slideTexts = slides.map { pageTexts[$0.upperBound] }
        let counts = slideTexts.map { Self.termCounts(Self.tokens($0)) }
        let documentFrequency = counts.reduce(into: [String: Int]()) { frequency, page in
            for term in page.keys { frequency[term, default: 0] += 1 }
        }
        let total = Double(max(1, slideTexts.count))
        let idf = documentFrequency.mapValues { log((total + 1) / (Double($0) + 1)) + 1 }
        self.idf = idf
        pages = counts.map { Self.normalized($0, idf: idf) }
        // No assumption about where the lecture starts: the student may start recording late, or the
        // teacher may carry on mid-deck from last week. The first few sentences decide.
        let count = max(1, slideTexts.count)
        belief = Array(repeating: 1 / Double(count), count: count)
    }

    var slideCount: Int { slides.count }

    var estimate: Estimate {
        let best = belief.indices.max { belief[$0] < belief[$1] } ?? 0
        return Estimate(slide: best, pages: slides.isEmpty ? 0...0 : slides[best], probability: belief.isEmpty ? 0 : belief[best])
    }

    /// Text for answering a question asked now: the shown slide and one on each side, since the tracker is
    /// often a slide behind or ahead (within one slide about 80 % of the time on the labelled lecture).
    func context(pageText: (Int) -> String) -> String {
        guard let shownSlide else { return "" }
        return context(around: shownSlide, pageText: pageText)
    }

    /// The given slide and one on each side.
    func context(around shownSlide: Int, pageText: (Int) -> String) -> String {
        guard slides.indices.contains(shownSlide) else { return "" }
        let around = max(0, shownSlide - 1)...min(slides.count - 1, shownSlide + 1)
        return around.map { slide in
            let page = slides[slide].upperBound
            let marker = slide == shownSlide ? "（最可能是这一页）" : ""
            return "[第 \(page + 1) 页\(marker)]\n" + pageText(page)
        }.joined(separator: "\n\n")
    }

    /// The slide a page belongs to.
    func slide(containing page: Int) -> Int? {
        slides.firstIndex { $0.contains(page) }
    }

    /// The page to show, or nil while the tracker isn't sure enough.
    var followedPage: Int? {
        estimate.probability >= configuration.followThreshold ? estimate.page : nil
    }

    /// The slide the reader shows: nil until the tracker is first confident, then changes only after it has
    /// preferred another slide with enough confidence for `confirmations` steps in a row.
    private(set) var shownSlide: Int?
    private var pendingSlide: (slide: Int, count: Int)?

    var shown: Estimate? {
        shownSlide.map { Estimate(slide: $0, pages: slides[$0], probability: belief[$0]) }
    }

    /// The transcript `tracker.configuration.window` seconds back from the newest of `segments`.
    func recentText(_ segments: [TranscriptSegment]) -> String {
        guard let newest = segments.last?.end else { return "" }
        return segments.filter { $0.isFinal && $0.end >= newest - configuration.window }.map(\.text).joined(separator: " ")
    }

    /// Slide texts as the tracker sees them (the last page of each slide), for `SlideLocator`.
    static func slideTexts(pageTexts: [String]) -> [String] {
        groupBuilds(pageTexts.map(tokens)).map { pageTexts[$0.upperBound] }
    }

    /// Advances one step with the transcript of the last `window` seconds. `hint` is the model's view of
    /// the slide, used as extra evidence: its slide's likelihood is multiplied by `1 + hintWeight × confidence`.
    mutating func update(recentTranscript text: String, hint: SlideLocator.Answer? = nil) {
        guard !pages.isEmpty else { return }
        let query = Self.normalized(Self.termCounts(Self.tokens(text)), idf: idf)
        let predicted = predict()
        guard !query.isEmpty || hint != nil else {
            belief = predicted
            updateShown()
            return
        }
        var likelihood = pages.map { query.isEmpty ? 1 : exp(Self.cosine(query, $0) / configuration.temperature) }
        if let hint, likelihood.indices.contains(hint.slide) {
            likelihood[hint.slide] *= 1 + configuration.hintWeight * hint.confidence
        }
        var posterior = zip(predicted, likelihood).map { $0 * $1 }
        let sum = posterior.reduce(0, +)
        guard sum > 0, sum.isFinite else {
            belief = predicted
            return
        }
        posterior = posterior.map { $0 / sum }
        belief = posterior
        updateShown()
    }

    private mutating func updateShown() {
        let best = estimate
        guard best.slide != shownSlide, best.probability >= configuration.followThreshold else {
            pendingSlide = nil
            return
        }
        let count = pendingSlide?.slide == best.slide ? (pendingSlide?.count ?? 0) + 1 : 1
        if count >= configuration.confirmations {
            shownSlide = best.slide
            pendingSlide = nil
        } else {
            pendingSlide = (best.slide, count)
        }
    }

    /// Belief after one step of the transition model, before looking at the new transcript.
    private func predict() -> [Double] {
        let count = pages.count
        // A jump to any slide stays possible, at a small total probability spread over all slides.
        let anywhere = configuration.jump / Double(count)
        var next = Array(repeating: 0.0, count: count)
        for (from, weight) in belief.enumerated() where weight > 0 {
            next[from] += weight * configuration.stay
            for (step, probability) in configuration.forward.enumerated() {
                next[min(count - 1, from + step + 1)] += weight * probability
            }
            next[max(0, from - 1)] += weight * configuration.back
            for page in 0..<count { next[page] += weight * anywhere }
        }
        let sum = next.reduce(0, +)
        return sum > 0 ? next.map { $0 / sum } : next
    }

    // MARK: Builds

    /// Groups consecutive pages where at least 80 % of a page's words reappear on the next one.
    static func groupBuilds(_ pageTokens: [[String]]) -> [ClosedRange<Int>] {
        guard !pageTokens.isEmpty else { return [] }
        var groups: [ClosedRange<Int>] = []
        var start = 0
        for index in 1..<max(1, pageTokens.count) where index < pageTokens.count {
            let previous = Set(pageTokens[index - 1])
            let next = Set(pageTokens[index])
            let contained = previous.isEmpty ? 0 : Double(previous.intersection(next).count) / Double(previous.count)
            if previous.isEmpty || contained < 0.8 {
                groups.append(start...(index - 1))
                start = index
            }
        }
        groups.append(start...(pageTokens.count - 1))
        return groups
    }

    // MARK: Text

    private static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "because",
        "been", "before", "being", "between", "both", "but", "by", "can", "could", "did", "do", "does", "doing", "don", "down",
        "each", "even", "few", "for", "from", "get", "go", "going", "gonna", "got", "had", "has", "have", "having", "he", "her", "here",
        "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "kind", "know", "let", "like", "me", "might", "more",
        "most", "much", "my", "no", "nor", "not", "now", "of", "off", "ok", "okay", "on", "once", "one", "only", "or", "other",
        "our", "out", "over", "own", "really", "right", "same", "say", "see", "she", "should", "so", "some", "such", "than",
        "that", "the", "their", "them", "then", "there", "these", "they", "thing", "things", "this", "those", "through", "to",
        "too", "uh", "um", "under", "until", "up", "us", "very", "want", "was", "way", "we", "well", "were", "what", "when",
        "where", "which", "while", "who", "why", "will", "with", "would", "yeah", "yes", "you", "your", "actually", "basically",
        "mean", "means", "something", "think", "use", "used", "using", "make", "makes", "two", "three", "first", "second",
    ]

    /// Spoken forms of the notation slides write as symbols.
    private static let spoken: [(String, String)] = [
        ("h zero", "h0"), ("h naught", "h0"), ("h nought", "h0"), ("h null", "h0"), ("h one", "h1"), ("h a", "ha"),
        ("t zero", "t0"), ("mu zero", "mu0"), ("theta zero", "theta0"), ("p value", "pvalue"), ("p-value", "pvalue"),
        ("type one", "type1"), ("type i ", "type1 "), ("type two", "type2"), ("type ii", "type2"),
    ]

    private static let greek: [Character: String] = [
        "θ": "theta", "μ": "mu", "α": "alpha", "β": "beta", "σ": "sigma", "π": "pi", "δ": "delta", "λ": "lambda", "ε": "epsilon",
    ]

    /// Words of `text` with notation, Greek letters and plurals unified so slides and speech meet.
    static func tokens(_ text: String) -> [String] {
        // Compatibility mapping turns mathematical italics (𝐻0, 𝜃) into plain letters (H0, θ).
        var folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        folded = String(folded.flatMap { greek[$0].map { " \($0) " } ?? String($0) })
        folded = folded.replacingOccurrences(of: "type-i", with: "type i ").replacingOccurrences(of: "type-ii", with: "type ii")
        for (said, written) in spoken {
            folded = folded.replacingOccurrences(of: said, with: written)
        }
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.compactMap { word in
            guard !stopwords.contains(word), word.count > 1 || word.first?.isNumber == false else { return nil }
            guard !word.allSatisfy(\.isNumber) else { return nil }
            if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
            if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("is") { return String(word.dropLast()) }
            return word
        }
    }

    private static func termCounts(_ tokens: [String]) -> [String: Double] {
        tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func normalized(_ counts: [String: Double], idf: [String: Double]) -> [String: Double] {
        var vector: [String: Double] = [:]
        for (term, count) in counts {
            guard let weight = idf[term] else { continue }
            vector[term] = (1 + log(count)) * weight
        }
        let norm = vector.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.mapValues { $0 / norm } : [:]
    }

    private static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let (small, large) = a.count < b.count ? (a, b) : (b, a)
        return small.reduce(0) { $0 + $1.value * (large[$1.key] ?? 0) }
    }
}
