import Foundation

/// Spots the teacher's real questions in the stream of final segments.
///
/// A segment that looks like a question opens a batch. The batch is checked by the model once the teacher
/// has said two more segments (enough to see whether they answered it themselves) or after 8 s of quiet;
/// questions asked back to back join the same batch. Checks run one at a time, in order. Nothing is
/// checked during a break (see `BreakWatcher`).
actor QuestionDetector {
    struct Configuration: Sendable {
        var followersToWait = 2
        var waitAfterLast: Duration = .seconds(8)
        /// A batch is checked at the latest this long after it opened, even if questions keep coming.
        var maximumBatchAge: Duration = .seconds(20)
        /// Segments before the first question given as context.
        var linesBefore = 6
    }

    struct Found: Sendable, Equatable {
        var segmentID: UUID
        var at: TimeInterval
        var quote: String
        var english: String
        var chinese: String
        /// Seconds from the question's segment arriving to it being found.
        var latency: Double
    }

    private struct Batch {
        var candidates: [UUID]
        var followers = 0
        var opened: ContinuousClock.Instant
    }

    nonisolated let found: AsyncStream<Found>
    private let continuation: AsyncStream<Found>.Continuation
    private let client: any LLMClient
    private let model: String
    private let configuration: Configuration
    private let clock = ContinuousClock()
    /// Recent final segments, numbered from the start of the session.
    private var history: [(number: Int, segment: TranscriptSegment)] = []
    private var nextNumber = 0
    private var arrivedAt: [UUID: ContinuousClock.Instant] = [:]
    /// Last time anything was heard, final or partial. A long sentence stays partial for up to 15 s, so
    /// finals alone would make the teacher look silent while they are still talking.
    private var lastSpeech: ContinuousClock.Instant?
    private var batch: Batch?
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var lastCheck: Task<Void, Never>?
    private var foundQuestions: [String] = []
    private var answeredSegments: Set<UUID> = []
    private var breaks = BreakWatcher()
    private(set) var modelCalls = 0
    private(set) var errors: [String] = []

    init(client: any LLMClient, model: String, configuration: Configuration = Configuration()) {
        self.client = client
        self.model = model
        self.configuration = configuration
        (found, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Returns when a break starts or ends on this segment.
    @discardableResult
    func observe(_ segment: TranscriptSegment) -> BreakWatcher.Change? {
        guard segment.isFinal, !segment.text.isEmpty else { return nil }
        let now = clock.now
        lastSpeech = now
        history.append((nextNumber, segment))
        nextNumber += 1
        if history.count > 80 { history.removeFirst(history.count - 80) }
        arrivedAt[segment.id] = now

        let change = breaks.observe(segment)
        if breaks.isOnBreak {
            // An open batch is dropped too: questions right before the break are about the break itself.
            batch = nil
            timer?.cancel()
            return change
        }

        if !QuestionCandidates.candidates(in: segment.text).isEmpty {
            if batch == nil { batch = Batch(candidates: [], opened: now) }
            batch?.candidates.append(segment.id)
            batch?.followers = 0
            restartTimer()
        } else if batch != nil {
            batch?.followers += 1
            if let batch, batch.followers >= configuration.followersToWait { check() }
        }
        if let batch, now - batch.opened >= configuration.maximumBatchAge { check() }
        return change
    }

    var isOnBreak: Bool { breaks.isOnBreak }

    /// The student turned spotting back on during what looked like a break.
    func endBreak() {
        breaks.end()
    }

    /// The teacher is still talking (a partial arrived); an open batch keeps waiting instead of
    /// reporting silence after the question.
    func noteSpeech() {
        lastSpeech = clock.now
    }

    /// A segment the student already had answered by hand, so it isn't found again.
    func markAnswered(_ segmentID: UUID) {
        answeredSegments.insert(segmentID)
    }

    /// Checks any open batch, waits for all checks, then ends `found`.
    func finish() async {
        check()
        await lastCheck?.value
        continuation.finish()
    }

    private func restartTimer(after wait: Duration? = nil) {
        timer?.cancel()
        timerGeneration += 1
        let generation = timerGeneration
        let wait = wait ?? configuration.waitAfterLast
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.timerFired(generation)
        }
    }

    private func timerFired(_ generation: Int) {
        guard generation == timerGeneration, let open = batch else { return }
        let now = clock.now
        let quiet = lastSpeech.map { now - $0 } ?? configuration.waitAfterLast
        if quiet < configuration.waitAfterLast, now - open.opened < configuration.maximumBatchAge {
            // Still talking: wait for the sentence to finish, or for the batch to reach its age limit.
            restartTimer(after: min(configuration.waitAfterLast - quiet, configuration.maximumBatchAge - (now - open.opened)))
            return
        }
        check(quietFor: quiet >= configuration.waitAfterLast ? quiet : nil)
    }

    /// `quietFor` is set when the check runs because nobody spoke for that long after the last segment.
    private func check(quietFor: Duration? = nil) {
        guard let current = batch else { return }
        batch = nil
        timer?.cancel()
        guard let firstIndex = history.firstIndex(where: { $0.segment.id == current.candidates.first }) else { return }
        let marked = Set(current.candidates)
        let window = Array(history[max(0, firstIndex - configuration.linesBefore)...])
        let previous = lastCheck
        let quiet = quietFor.map { Int($0.components.seconds) }
        lastCheck = Task {
            await previous?.value
            await run(window: window, marked: marked, quietAfter: quiet)
        }
    }

    private func run(window: [(number: Int, segment: TranscriptSegment)], marked: Set<UUID>, quietAfter: Int?) async {
        // The pause after a line is the gap to the next one; each segment keeps 0.2 s of padding on both sides.
        let lines = window.indices.map { index in
            let segment = window[index].segment
            let pause = index + 1 < window.count ? window[index + 1].segment.start - segment.end + 0.4 : nil
            return (number: window[index].number, time: segment.start, pause: pause, text: segment.text, marked: marked.contains(segment.id))
        }
        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: QuestionPrompts.findSystem),
                ChatMessage(role: .user, content: QuestionPrompts.findUser(lines: lines, found: Array(foundQuestions.suffix(20)), quietAfter: quietAfter)),
            ],
            temperature: 0,
            maxTokens: 600,
            jsonOutput: true
        )
        modelCalls += 1
        let reply: String
        do {
            reply = try await client.complete(request)
        } catch {
            errors.append(error.localizedDescription)
            return
        }
        for entry in Self.parse(reply) where entry.isDirected {
            // Only questions on marked lines count; a model pointing elsewhere is ignored.
            guard let item = window.first(where: { $0.number == entry.line }), marked.contains(item.segment.id),
                  !answeredSegments.contains(item.segment.id) else { continue }
            let english = entry.english?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !english.isEmpty, !foundQuestions.contains(where: { Self.isDuplicate(english, of: $0) }) else { continue }
            foundQuestions.append(english)
            answeredSegments.insert(item.segment.id)
            let latency = arrivedAt[item.segment.id].map { Self.seconds(clock.now - $0) } ?? 0
            continuation.yield(Found(
                segmentID: item.segment.id,
                at: item.segment.start,
                quote: item.segment.text,
                english: english,
                chinese: entry.chinese?.trimmingCharacters(in: .whitespacesAndNewlines) ?? english,
                latency: latency
            ))
        }
    }

    struct Entry: Decodable, Equatable {
        var line: Int?
        var kind: String?
        var signal: String?
        var evidence: String?
        var english: String?
        var chinese: String?

        /// Signals that show students were meant to answer. A pause on its own isn't one: most false
        /// positives in Week 7 were questions followed by nothing but silence or laughter.
        static let answerSignals: Set<String> = ["student-answer", "teacher-repeats", "invites-answer", "reacts-to-answer"]

        var isDirected: Bool {
            kind == "directed" && signal.map(Self.answerSignals.contains) == true
        }
    }

    /// Reads the model's JSON, tolerating text around it.
    static func parse(_ reply: String) -> [Entry] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return [] }
        struct Reply: Decodable { var questions: [Entry] }
        return (try? JSONDecoder().decode(Reply.self, from: Data(reply[start...end].utf8)))?.questions ?? []
    }

    /// Same question reworded: most of the shorter one's words appear in the longer one.
    static func isDuplicate(_ a: String, of b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        }
        let (x, y) = (words(a), words(b))
        guard let smaller = [x, y].min(by: { $0.count < $1.count }), !smaller.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(smaller.count) >= 0.8
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
