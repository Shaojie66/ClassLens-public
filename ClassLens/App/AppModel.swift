import AppKit
import AVFoundation
import Foundation
import Observation
import OSLog

/// App-wide UI state. Audio and recognition run off the main actor; this model wires them together
/// and shows their results.
@MainActor
@Observable
final class AppModel {
    enum EngineState: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    enum Source: Equatable {
        case microphone
        case replay(URL)

        var label: String {
            switch self {
            case .microphone: "microphone"
            case .replay(let url): "replay:\(url.lastPathComponent)"
            }
        }
    }

    enum Activity: Equatable {
        case idle
        case listening(Source, startedAt: Date)
        /// Audio has stopped; the last utterances are still being transcribed.
        case finishing
    }

    var engineState: EngineState = .idle
    var activity: Activity = .idle
    var segments: [TranscriptSegment] = []
    /// Input level of the latest chunk, 0…1.
    var level: Float = 0
    /// Seconds of audio received in the current session.
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    /// The slides on the left; nil until the student opens a PDF.
    var document: LectureDocument?
    /// 0-based page the student is looking at.
    var currentPage = 0
    var glossaryState: GlossaryState = .none
    /// Name of the app converting a PowerPoint/Keynote file, while it works.
    var convertingWith: String?
    /// The slide the teacher seems to be on, from the transcript; nil without slides or before speech.
    var teacherSlide: SlideTracker.Estimate?
    /// Setting: turn the reader to the teacher's slide. (Key renamed from "followTeacher", which an early
    /// build could set to false by mistake when PDFKit reported a page change during layout.)
    var followTeacher = UserDefaults.standard.object(forKey: "followTeacherEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followTeacher, forKey: "followTeacherEnabled") }
    }
    /// The student turned a page by hand; following waits until they resume. Not saved.
    var followPaused = false

    var isFollowing: Bool { followTeacher && !followPaused }
    /// Use the fast model to work out the teacher's slide (more accurate than word overlap, about $0.03 a lecture).
    var slideLocatorEnabled = UserDefaults.standard.object(forKey: "slideLocatorEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(slideLocatorEnabled, forKey: "slideLocatorEnabled") }
    }
    /// Set to ask the side pane to show the Q&A tab, e.g. after asking about a selection.
    var showQuestionsTab = false
    /// A selection waiting for the student to type their own question.
    var pendingSelection: TextSelection?
    /// What is selected right now in the slides or a caption, for ⌘E.
    var activeSelection: TextSelection?
    var classroomMicrophone = UserDefaults.standard.bool(forKey: "classroomMicrophone") {
        didSet { UserDefaults.standard.set(classroomMicrophone, forKey: "classroomMicrophone") }
    }
    var translationEnabled = UserDefaults.standard.object(forKey: "translationEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(translationEnabled, forKey: "translationEnabled") }
    }
    /// Whether an API key for the AI provider is saved; the key itself never leaves the keychain helper.
    private(set) var hasAPIKey = Keychain.read(LLMProvider.deepSeek.keychainAccount) != nil
    /// Final segments whose Chinese is on its way.
    private(set) var translating: Set<UUID> = []
    var questionsEnabled = UserDefaults.standard.object(forKey: "questionsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(questionsEnabled, forKey: "questionsEnabled") }
    }
    /// Lecture time the current break started; question spotting is paused until it ends.
    var breakSince: TimeInterval?
    /// The teacher's questions in this session, newest last.
    var questions: [ClassQuestion] = []
    /// Set when a new question arrives, so the Q&A tab can show it.
    var unseenQuestions = 0
    let provider = LLMProvider.deepSeek

    @ObservationIgnored private var engine: Qwen3ASREngine?
    @ObservationIgnored private var engineLoad: Task<Qwen3ASREngine, Error>?
    @ObservationIgnored private var microphone: MicrophoneSource?
    @ObservationIgnored private var replay: AudioFileReplay?
    @ObservationIgnored private var session: Task<TranscriptionMetrics.Report?, Never>?
    @ObservationIgnored private var peakMemoryMB: Double = 0
    @ObservationIgnored private var translationLatencies: [Double] = []
    @ObservationIgnored private var translationErrors = 0
    @ObservationIgnored var store: SessionStore?
    /// The running session's transcriber and translator, so a glossary opened mid-lecture reaches them.
    @ObservationIgnored var activeTranscriber: LiveTranscriber?
    @ObservationIgnored var activeTranslator: SegmentTranslator?
    @ObservationIgnored var activeDetector: QuestionDetector?
    @ObservationIgnored var glossary: Glossary?
    @ObservationIgnored var slideTracker: SlideTracker?
    @ObservationIgnored var lastRecordedSlide: Int?
    /// Past lectures, newest first.
    var history: [SessionSummary] = []
    /// The past lecture being reviewed; nil in the live view.
    var reviewing: LoadedSession?
    /// Playback position while reviewing, in seconds.
    var playbackTime: TimeInterval = 0
    /// Mirrors the player, which SwiftUI can't observe.
    var playing = false
    var exportState: ExportState = .idle
    @ObservationIgnored var player: AVAudioPlayer?
    @ObservationIgnored var playbackClock: Task<Void, Never>?
    /// Asks the model which slide the teacher is on every 30 s; the word tracker covers the gaps.
    @ObservationIgnored var slideLocator: SlideLocator?
    @ObservationIgnored var locatedSlide: SlideLocator.Answer?
    @ObservationIgnored var lastLocatedAt: TimeInterval = -.infinity
    @ObservationIgnored var locating = false
    /// Set by `--asr-only`: this run transcribes without translation or question spotting.
    @ObservationIgnored var asrOnly = false
    @ObservationIgnored private var questionLatencies: [Double] = []
    @ObservationIgnored private var answerFirstPieceLatencies: [Double] = []
    @ObservationIgnored private var answerTotalLatencies: [Double] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.chenshaojie.ClassLens", category: "AppModel")

    var isListening: Bool {
        if case .listening = activity { true } else { false }
    }

    // MARK: Engine

    @discardableResult
    func loadEngine() async throws -> Qwen3ASREngine {
        if let engine { return engine }
        if let engineLoad { return try await engineLoad.value }
        engineState = .downloading(0)
        let task = Task {
            try await Qwen3ASREngine.load { [weak self] fraction in
                guard let self else { return }
                self.engineState = fraction < 1 ? .downloading(fraction) : .loading
            }
        }
        engineLoad = task
        do {
            let loaded = try await task.value
            engine = loaded
            engineState = .ready
            return loaded
        } catch {
            engineLoad = nil
            engineState = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: Sessions

    func toggleMicrophone() {
        if isListening {
            stop()
        } else {
            Task { await startMicrophone() }
        }
    }

    func startMicrophone() async {
        let microphone = MicrophoneSource()
        self.microphone = microphone
        await run(source: .microphone) { [classroomMicrophone] in
            try await microphone.start(classroomMode: classroomMicrophone)
        }
    }

    @discardableResult
    func startReplay(_ replay: AudioFileReplay) async -> TranscriptionMetrics.Report? {
        self.replay = replay
        await run(source: .replay(replay.url)) { replay.stream() }
        return await session?.value
    }

    func chooseReplayFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "选择一段课堂录音，按真实速度回放并转录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await startReplay(AudioFileReplay(url: url)) }
    }

    func stop() {
        microphone?.stop()
        microphone = nil
        replay?.stop()
        replay = nil
    }

    /// Starts a session and returns once audio is flowing; the session's task runs until the audio ends.
    private func run(source: Source, open: @escaping () async throws -> AsyncThrowingStream<[Float], Error>) async {
        guard activity == .idle else { return }
        session = nil
        errorMessage = nil
        let engine: Qwen3ASREngine
        let store: SessionStore
        let audio: AsyncThrowingStream<[Float], Error>
        do {
            engine = try await loadEngine()
            store = try SessionStore(source: source.label, engine: engine.name, document: documentRecord)
            audio = try await open()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if reviewing != nil { leaveReview() }
        segments = []
        elapsed = 0
        lastRecordedSlide = nil
        activity = .listening(source, startedAt: .now)
        logger.notice("Session started: \(source.label, privacy: .public) → \(store.directory.path, privacy: .public)")
        session = Task { await self.record(audio, engine: engine, store: store) }
    }

    private func record(_ audio: AsyncThrowingStream<[Float], Error>, engine: Qwen3ASREngine, store: SessionStore) async -> TranscriptionMetrics.Report? {
        let transcriber = LiveTranscriber(engine: engine)
        let translator = makeTranslator()
        let detector = makeDetector()
        self.store = store
        activeTranscriber = transcriber
        activeTranslator = translator
        activeDetector = detector
        breakSince = nil
        await applyGlossary()
        questions = []
        unseenQuestions = 0
        translationLatencies = []
        translationErrors = 0
        questionLatencies = []
        answerFirstPieceLatencies = []
        answerTotalLatencies = []
        let answering = Task {
            guard let detector else { return }
            await withTaskGroup { answers in
                for await found in detector.found {
                    questionLatencies.append(found.latency)
                    let question = ClassQuestion(segmentID: found.segmentID, at: found.at, quote: found.quote, english: found.english, chinese: found.chinese, origin: .detected, page: document.map { _ in (teacherSlide?.page ?? currentPage) + 1 })
                    answers.addTask { await self.answer(question) }
                }
            }
        }
        let display = Task {
            await withTaskGroup { translations in
                for await event in transcriber.events {
                    apply(event)
                    if case .partial = event { await detector?.noteSpeech() }
                    guard case .final(let segment) = event, !segment.text.isEmpty else { continue }
                    trackSlide()
                    switch await detector?.observe(segment) {
                    case .started(let at):
                        breakSince = at
                        logger.notice("Break started at \(at, format: .fixed(precision: 1))s; question spotting paused")
                    case .ended(let at):
                        breakSince = nil
                        logger.notice("Break ended at \(at, format: .fixed(precision: 1))s; question spotting resumed")
                    case nil: break
                    }
                    // Written before its translation is requested, so the translated line always comes later.
                    await persist(segment, to: store)
                    guard let translator else { continue }
                    translating.insert(segment.id)
                    translations.addTask {
                        let outcome = await translator.translate(segment)
                        if let translated = await self.finishTranslation(outcome) {
                            await self.persist(translated, to: store)
                        }
                    }
                }
            }
        }
        peakMemoryMB = MemoryUsage.footprintMB()
        let memory = Task {
            while !Task.isCancelled {
                peakMemoryMB = max(peakMemoryMB, MemoryUsage.footprintMB())
                try? await Task.sleep(for: .seconds(2))
            }
        }
        do {
            for try await chunk in audio {
                await transcriber.append(chunk)
                try await store.writeAudio(chunk)
                level = LectureAudio.rms(chunk)
                elapsed = await transcriber.receivedSeconds
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        activity = .finishing
        level = 0
        await transcriber.finish()
        await display.value
        await detector?.finish()
        await answering.value
        memory.cancel()
        peakMemoryMB = max(peakMemoryMB, MemoryUsage.footprintMB())
        do { try await store.close(duration: elapsed) } catch { errorMessage = "录音保存失败：\(error.localizedDescription)" }
        var report = await transcriber.metrics.report(engine: engine.name, audioSeconds: elapsed, peakMemoryMB: peakMemoryMB, sessionDirectory: store.directory)
        if translator != nil {
            report.translationLatency = TranscriptionMetrics.Distribution(translationLatencies)
            report.translationErrors = translationErrors
        }
        if let detector {
            report.questions = questions.map { .init(at: $0.at, quote: $0.quote, english: $0.english, status: $0.status.rawValue) }
            report.questionLatency = TranscriptionMetrics.Distribution(questionLatencies)
            report.answerFirstPieceLatency = TranscriptionMetrics.Distribution(answerFirstPieceLatencies)
            report.answerTotalLatency = TranscriptionMetrics.Distribution(answerTotalLatencies)
            report.questionModelCalls = await detector.modelCalls
            report.questionErrors = await detector.errors.count + questions.filter { $0.status == .failed }.count
        }
        logger.notice("Session finished: final p95 \(report.finalLatency.p95, format: .fixed(precision: 2))s, partial p95 \(report.partialLatency.p95, format: .fixed(precision: 2))s, peak \(Int(report.peakMemoryMB)) MB")
        activity = .idle
        microphone = nil
        replay = nil
        activeTranscriber = nil
        activeTranslator = nil
        activeDetector = nil
        breakSince = nil
        report.glossaryTerms = glossary?.terms.count
        refreshHistory()
        return report
    }

    /// The translator for a session, or nil when translation is off or no key is saved.
    private func makeTranslator() -> SegmentTranslator? {
        guard translationEnabled, !asrOnly else { return nil }
        do {
            return SegmentTranslator(client: try OpenAICompatibleClient.load(provider), model: provider.fastModel)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func makeDetector() -> QuestionDetector? {
        guard questionsEnabled, !asrOnly, let client = try? OpenAICompatibleClient.load(provider) else { return nil }
        return QuestionDetector(client: client, model: provider.fastModel)
    }

    // MARK: Questions

    /// Turns question spotting back on when the break detection was wrong or the class came back quietly.
    func endBreak() {
        breakSince = nil
        Task { await activeDetector?.endBreak() }
    }

    /// Answers a line the detector missed; the student picks it from the transcript.
    func answerManually(_ segmentID: UUID) {
        guard let segment = segments.first(where: { $0.id == segmentID }),
              !questions.contains(where: { $0.segmentID == segmentID }) else { return }
        let question = ClassQuestion(segmentID: segment.id, at: segment.start, quote: segment.text, english: segment.text, chinese: segment.translation ?? "", origin: .manual)
        Task { await answer(question) }
    }

    /// Whether the teacher asked a question in this caption (the student's own questions don't count).
    func isQuestion(_ segmentID: UUID) -> Bool {
        questions.contains { $0.segmentID == segmentID && $0.origin.isTeachers }
    }

    func answer(_ question: ClassQuestion) async {
        questions.append(question)
        unseenQuestions += 1
        let id = question.id
        let clock = ContinuousClock()
        let started = clock.now
        func seconds() -> Double {
            let elapsed = clock.now - started
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        do {
            let answerer = QuestionAnswerer(client: try OpenAICompatibleClient.load(provider), model: provider.strongModel)
            var first = true
            let glossaryLines = glossary?.translationLines ?? []
            let stream: AsyncThrowingStream<String, Error>
            switch question.origin {
            case .selection:
                stream = answerer.answerSelection(question: question.english, selection: question.quote, page: question.page ?? 1, pageText: document?.pageText((question.page ?? 1) - 1) ?? "", context: recentContext(before: .infinity).suffix(15).map { $0 }, glossary: glossaryLines)
            case .caption:
                let sentence = segments.first { $0.id == question.segmentID }
                stream = answerer.answerCaption(question: question.english, selection: question.quote, sentence: sentence?.text ?? question.quote, translation: sentence?.translation, around: captionContext(around: question.segmentID), slide: question.page.flatMap { page in document.map { $0.pageText(page - 1) } }, glossary: glossaryLines)
            case .detected, .manual:
                stream = answerer.answer(question, context: recentContext(before: question.at + 30), glossary: glossaryLines, slide: slideContext(for: question))
            }
            for try await piece in stream {
                if first {
                    answerFirstPieceLatencies.append(seconds())
                    first = false
                }
                update(id) { $0.answer += piece }
            }
            answerTotalLatencies.append(seconds())
            update(id) { $0.status = .answered }
        } catch {
            update(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
            }
        }
        await saveQuestions()
    }

    /// About four minutes of final transcript up to `time`, as "[m:ss] text" lines.
    /// Five captions before and after a caption, as "[m:ss] text" lines.
    func captionContext(around segmentID: UUID) -> [String] {
        let finals = segments.filter(\.isFinal)
        guard let index = finals.firstIndex(where: { $0.id == segmentID }) else { return [] }
        return finals[max(0, index - 5)...min(finals.count - 1, index + 5)].map { "[\(QuestionPrompts.clock($0.start))] \($0.text)" }
    }

    func recentContext(before time: TimeInterval) -> [String] {
        segments.filter { $0.isFinal && $0.start <= time }.suffix(40).map { "[\(QuestionPrompts.clock($0.start))] \($0.text)" }
    }

    private func update(_ id: UUID, _ change: (inout ClassQuestion) -> Void) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        change(&questions[index])
    }

    /// Saves the questions to the lecture they belong to: the one being reviewed, else the one recording.
    func saveQuestions() async {
        do {
            if let reviewing {
                try SessionLibrary.writeQuestions(questions, to: reviewing.summary.directory)
                self.reviewing?.questions = questions
            } else if let store {
                try await store.writeQuestions(questions)
            }
        } catch {
            errorMessage = "问答保存失败：\(error.localizedDescription)"
        }
    }

    private func persist(_ segment: TranscriptSegment, to store: SessionStore) async {
        do { try await store.append(segment) } catch { errorMessage = "转录保存失败：\(error.localizedDescription)" }
    }

    /// Shows a translation and returns the updated segment to save, or nil on failure.
    private func finishTranslation(_ outcome: SegmentTranslator.Outcome) -> TranscriptSegment? {
        translating.remove(outcome.id)
        translationLatencies.append(outcome.latency)
        if let error = outcome.error {
            translationErrors += 1
            errorMessage = "翻译失败：\(error)"
            return nil
        }
        guard let index = segments.lastIndex(where: { $0.id == outcome.id }) else { return nil }
        segments[index].translation = outcome.translation
        return segments[index]
    }

    // MARK: Settings

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.save(trimmed, for: provider.keychainAccount)
        hasAPIKey = !trimmed.isEmpty
    }

    func deleteAPIKey() throws {
        try Keychain.delete(provider.keychainAccount)
        hasAPIKey = false
    }

    /// Translates one sentence with the saved key, to check the key and the connection.
    func testTranslation() async -> Result<String, Error> {
        do {
            let translator = SegmentTranslator(client: try OpenAICompatibleClient.load(provider), model: provider.fastModel)
            let sample = TranscriptSegment(start: 0, end: 3, text: "The null hypothesis says the two methods have the same expected accuracy.", isFinal: true)
            let outcome = await translator.translate(sample)
            if let error = outcome.error { throw TestFailure(message: error) }
            return .success(String(format: "%@（%.1f 秒）", outcome.translation ?? "", outcome.latency))
        } catch {
            return .failure(error)
        }
    }

    private struct TestFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private func apply(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let segment), .final(let segment):
            // The segment being updated is almost always among the last few.
            let index = segments.lastIndex { $0.id == segment.id }
            if segment.isFinal, segment.text.isEmpty {
                if let index { segments.remove(at: index) }
            } else if let index {
                segments[index] = segment
            } else {
                segments.append(segment)
            }
        case .failed(let message):
            errorMessage = "识别出错：\(message)"
        }
    }

    // MARK: Launch

    /// `--export latest|<id> [--export-folder dir] [--no-audio] [--no-summary]`: exports without the sheet.
    private func exportFromCommandLine(_ wanted: String, options: LaunchOptions) async {
        refreshHistory()
        guard let summary = wanted == "latest" ? history.first : history.first(where: { $0.id.uuidString == wanted }) else {
            print("export failed: no session \(wanted)")
            return
        }
        await review(summary)
        guard let session = reviewing else {
            print("export failed: \(errorMessage ?? "cannot load")")
            return
        }
        let location = defaultExportLocation(for: session)
        guard let folder = options.exportFolder ?? location?.classLensFolder else {
            print("export failed: no vault location; pass --export-folder")
            return
        }
        let plan = ExportPlan(folder: folder, course: location?.course ?? "COURSE", week: defaultWeek(for: session), lectureDate: options.lectureDate ?? summary.meta.createdAt, includeTranscript: !options.summaryOnly, includeAudio: !options.noAudio && !options.summaryOnly, includeSummary: !options.noSummary)
        await export(session, plan: plan)
        switch exportState {
        case .done(let files, let summaryError):
            files.forEach { print("exported \($0.path)") }
            if let summaryError { print("summary error \(summaryError)") }
        case .failed(let message): print("export failed: \(message)")
        default: print("export failed: unexpected state")
        }
    }

    /// Feeds a saved transcript to question spotting, so prompt changes can be compared without re-running recognition.
    private func evalQuestions(_ url: URL) async {
        do {
            let detector = QuestionDetector(client: try OpenAICompatibleClient.load(provider), model: provider.fastModel)
            let collector = Task {
                var found: [QuestionDetector.Found] = []
                for await item in detector.found { found.append(item) }
                return found
            }
            for segment in try SessionStore.loadTranscript(url) {
                switch await detector.observe(segment) {
                case .started(let at): print(String(format: "break started %.1f", at))
                case .ended(let at): print(String(format: "break ended %.1f", at))
                case nil: break
                }
            }
            await detector.finish()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for item in await collector.value {
                let line = ["at": String(format: "%.1f", item.at), "english": item.english, "quote": item.quote]
                print("question " + String(decoding: try encoder.encode(line), as: UTF8.self))
            }
            print("calls \(await detector.modelCalls) errors \(await detector.errors.count)")
        } catch {
            print("eval failed: \(error.localizedDescription)")
        }
    }

    /// Runs slide tracking over a saved transcript: one line per segment,
    /// "time best-slide page probability shown-slide".
    /// CLASSLENS_SLIDES_MODE=llm uses only the model (asked every 30 s of transcript); =hybrid feeds its
    /// answers to the tracker as evidence; unset uses word overlap alone.
    private func evalSlides(_ url: URL) async {
        guard let document else {
            print("eval failed: no document")
            return
        }
        do {
            var configuration = SlideTracker.Configuration()
            // CLASSLENS_SLIDES="temperature=0.15 jump=0.0005" overrides settings for tuning runs.
            if let settings = ProcessInfo.processInfo.environment["CLASSLENS_SLIDES"] { configuration.apply(settings) }
            let pageTexts = (0..<document.pageCount).map(document.pageText)
            var tracker = SlideTracker(pageTexts: pageTexts, configuration: configuration)
            print("slides \(tracker.slideCount): " + tracker.slides.map { $0.count == 1 ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)-\($0.upperBound + 1)" }.joined(separator: " "))
            let mode = ProcessInfo.processInfo.environment["CLASSLENS_SLIDES_MODE"] ?? "words"
            let locator = mode == "words" ? nil : SlideLocator(client: try OpenAICompatibleClient.load(provider), model: provider.fastModel, slideTexts: SlideTracker.slideTexts(pageTexts: pageTexts))
            var seen: [TranscriptSegment] = []
            var lastAsked: TimeInterval = -.infinity
            var answer: SlideLocator.Answer?
            var calls = 0
            for segment in try SessionStore.loadTranscript(url) where segment.isFinal {
                seen.append(segment)
                var fresh: SlideLocator.Answer?
                if let locator, segment.end - lastAsked >= 30 {
                    lastAsked = segment.end
                    let recent = seen.filter { $0.end >= segment.end - 90 }.map(\.text).joined(separator: " ")
                    calls += 1
                    if let located = try? await locator.locate(recent: recent, previous: answer?.slide) {
                        answer = located
                        fresh = located
                    }
                }
                if mode == "llm" {
                    let slide = answer?.slide ?? 0
                    let pages = tracker.slides[slide]
                    print(String(format: "slide %.1f %d %d %.3f %d", segment.end, slide + 1, pages.upperBound + 1, answer?.confidence ?? 0, answer.map { $0.slide + 1 } ?? 0))
                    continue
                }
                tracker.update(recentTranscript: tracker.recentText(seen), hint: fresh)
                let estimate = tracker.estimate
                // 0 means no slide is shown yet.
                let shown = tracker.shown.map { $0.slide + 1 } ?? 0
                print(String(format: "slide %.1f %d %d %.3f %d", segment.end, estimate.slide + 1, estimate.page + 1, estimate.probability, shown))
            }
            if locator != nil { print("calls \(calls)") }
        } catch {
            print("eval failed: \(error.localizedDescription)")
        }
    }

    /// Times the recognizer alone, without segmentation or scheduling, to separate model speed from pipeline overhead.
    private func benchEngine(_ url: URL, start: TimeInterval) async {
        do {
            let engine = try await loadEngine()
            var audio: [Float] = []
            for try await chunk in AudioFileReplay(url: url, start: start, duration: 60, speed: 0).stream() { audio += chunk }
            let clock = ContinuousClock()
            for seconds in [2.0, 5.0, 10.0, 15.0, 30.0, 60.0] {
                let slice = Array(audio.prefix(Int(seconds * LectureAudio.sampleRate)))
                var times: [Double] = []
                for _ in 0..<3 {
                    let started = clock.now
                    _ = try await engine.transcribe(slice, context: "")
                    let elapsed = clock.now - started
                    times.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                }
                let best = times.min() ?? 0
                print(String(format: "bench %5.1fs audio: best %.2fs (%.1fx), runs %@", seconds, best, seconds / best, times.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            }
        } catch {
            print("bench failed: \(error.localizedDescription)")
        }
    }

    /// Runs the headless replay described by the command line, if any.
    func handleLaunchOptions(_ options: LaunchOptions = LaunchOptions()) async {
        asrOnly = options.asrOnly
        if let url = options.document {
            await openDocument(url)
            if let transcript = options.evalSlides {
                await evalSlides(transcript)
                NSApp.terminate(nil)
                return
            }
            if options.replay == nil, options.quitWhenDone {
                // Headless check of import: report what was opened, then quit.
                print("document \(document?.name ?? "-") pages \(document?.pageCount ?? 0) glossary \(glossary?.terms.count ?? 0) source \(document?.sourceURL?.lastPathComponent ?? "-") pdf \(document?.url.path ?? "-")")
                if let errorMessage { print("error \(errorMessage)") }
                NSApp.terminate(nil)
                return
            }
        }
        if let url = options.benchEngine {
            await benchEngine(url, start: options.replayStart)
            NSApp.terminate(nil)
            return
        }
        if let url = options.evalQuestions {
            await evalQuestions(url)
            NSApp.terminate(nil)
            return
        }
        if let wanted = options.export {
            await exportFromCommandLine(wanted, options: options)
            NSApp.terminate(nil)
            return
        }
        if let wanted = options.review {
            refreshHistory()
            let summary = wanted == "latest" ? history.first : history.first { $0.id.uuidString == wanted }
            if let summary {
                await review(summary)
                if let start = options.playFrom { play(from: start) }
                if let wait = options.reportAfter {
                    try? await Task.sleep(for: .seconds(wait))
                    print("review title=\(summary.title) segments=\(segments.count) questions=\(questions.count) document=\(document?.name ?? "-") playing=\(isPlaying) time=\(String(format: "%.1f", playbackTime)) teacherPage=\(teacherSlide.map { "\($0.page + 1)" } ?? "-") readerPage=\(currentPage + 1) following=\(isFollowing)")
                    NSApp.terminate(nil)
                }
            } else {
                errorMessage = "找不到要回看的课：\(wanted)"
            }
            return
        }
        guard let url = options.replay else {
            // Get the model ready in the background so the first recording starts at once.
            _ = try? await loadEngine()
            return
        }
        let replay = AudioFileReplay(url: url, start: options.replayStart, duration: options.replayDuration, speed: options.replaySpeed)
        let report = await startReplay(replay)
        if let report, let out = options.metricsOut {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(report).write(to: out)
            } catch {
                logger.error("Could not write metrics: \(error.localizedDescription, privacy: .public)")
            }
        }
        if report == nil, let errorMessage {
            logger.error("Replay failed: \(errorMessage, privacy: .public)")
        }
        if options.quitWhenDone {
            NSApp.terminate(nil)
        }
    }
}
