import AppKit
import Foundation
import UniformTypeIdentifiers

enum GlossaryState: Equatable {
    case none
    case extracting
    case ready(Int)
    case failed(String)
}

/// Where selected text came from.
enum SelectionSource: Equatable, Sendable {
    /// A slide page, 1-based.
    case slide(page: Int)
    /// A caption, by segment id.
    case caption(segmentID: UUID)
}

/// Text the student selected, in the slides or in a caption.
struct TextSelection: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var source: SelectionSource
}

enum SelectionAction {
    case explain
    case translate
    case ask(String)

    var question: String {
        switch self {
        case .explain: "请解释这段内容的意思，以及它在这门课里的作用。"
        case .translate: "请把这段内容准确翻译成中文，保留公式和符号。"
        case .ask(let question): question
        }
    }
}

extension AppModel {
    // MARK: Opening

    /// PDF plus the slide formats SlideConverter can export.
    static var documentTypes: [UTType] {
        [.pdf] + SlideConverter.convertibleExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || SlideConverter.convertibleExtensions.contains(ext)
    }

    func chooseDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.documentTypes
        panel.message = "选择课件（PPT、Keynote 或 PDF）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openDocument(url) }
    }

    /// Opens a PDF, or converts PowerPoint/Keynote to PDF first, then loads its glossary from the cache
    /// or extracts one.
    func openDocument(_ url: URL) async {
        do {
            if SlideConverter.convertibleExtensions.contains(url.pathExtension.lowercased()) {
                defer { convertingWith = nil }
                let pdf = try await SlideConverter.pdf(for: url) { self.convertingWith = $0 }
                document = try LectureDocument(url: pdf, source: url)
            } else {
                document = try LectureDocument(url: url)
            }
            currentPage = 0
            glossary = nil
            glossaryState = .none
            if let document {
                let pageTexts = (0..<document.pageCount).map(document.pageText)
                slideTracker = SlideTracker(pageTexts: pageTexts)
                slideLocator = makeSlideLocator(pageTexts: pageTexts)
                locatedSlide = nil
                lastLocatedAt = -.infinity
                teacherSlide = nil
                followPaused = false
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Slides opened during a recording belong to that lecture.
        if isListening, let store, let record = documentRecord {
            do { try await store.setDocument(record) } catch { errorMessage = "课件记录保存失败：\(error.localizedDescription)" }
        }
        await loadGlossary()
    }

    private func loadGlossary() async {
        guard let document else { return }
        if let cached = GlossaryCache.load(document.fingerprint) {
            await use(cached)
            return
        }
        guard let client = try? OpenAICompatibleClient.load(provider) else {
            glossaryState = .failed("填写 API key 后才能从课件抽取术语表")
            return
        }
        glossaryState = .extracting
        let fingerprint = document.fingerprint
        do {
            let extracted = try await GlossaryExtractor(client: client, model: provider.fastModel).extract(text: document.fullText(), fingerprint: fingerprint)
            // The student may have opened another file meanwhile.
            guard self.document?.fingerprint == fingerprint else { return }
            try? GlossaryCache.save(extracted)
            await use(extracted)
        } catch {
            glossaryState = .failed(error.localizedDescription)
        }
    }

    private func use(_ glossary: Glossary) async {
        self.glossary = glossary
        glossaryState = .ready(glossary.terms.count)
        await applyGlossary()
    }

    /// Hands the glossary to a running session's recognizer and translator.
    func applyGlossary() async {
        guard let glossary else { return }
        await activeTranscriber?.setVocabulary(glossary.recognitionTerms)
        await activeTranslator?.setGlossary(glossary.translationLines)
    }

    // MARK: Following the teacher

    private func makeSlideLocator(pageTexts: [String]) -> SlideLocator? {
        guard slideLocatorEnabled, !asrOnly, let client = try? OpenAICompatibleClient.load(provider) else { return nil }
        return SlideLocator(client: client, model: provider.fastModel, slideTexts: SlideTracker.slideTexts(pageTexts: pageTexts))
    }

    /// Updates the teacher's slide from the transcript so far, and turns the reader if following.
    ///
    /// The model is asked every 30 s of transcript, one request at a time; its latest answer is the
    /// teacher's slide. Word overlap (`SlideTracker`) runs on every segment and is used until the model has
    /// answered, or when it is off or failing. On the labelled lecture the model got 13/16 held-out moments
    /// exactly right against 6/16 for word overlap (docs/decisions.md).
    func trackSlide() {
        guard var tracker = slideTracker else { return }
        let finals = segments.filter(\.isFinal)
        tracker.update(recentTranscript: tracker.recentText(finals))
        slideTracker = tracker
        if let located = locatedSlide, tracker.slides.indices.contains(located.slide) {
            show(SlideTracker.Estimate(slide: located.slide, pages: tracker.slides[located.slide], probability: located.confidence))
        } else {
            show(tracker.shown)
        }
        guard let locator = slideLocator, !locating, let newest = finals.last?.end, newest - lastLocatedAt >= 30 else { return }
        locating = true
        lastLocatedAt = newest
        let recent = finals.filter { $0.end >= newest - 90 }.map(\.text).joined(separator: " ")
        let previous = locatedSlide?.slide
        Task {
            defer { locating = false }
            // A failed call leaves the word tracker in charge until the next one succeeds.
            guard let answer = try? await locator.locate(recent: recent, previous: previous) else {
                locatedSlide = nil
                return
            }
            locatedSlide = answer
            if let tracker = slideTracker, tracker.slides.indices.contains(answer.slide) {
                show(SlideTracker.Estimate(slide: answer.slide, pages: tracker.slides[answer.slide], probability: answer.confidence))
            }
        }
    }

    private func show(_ estimate: SlideTracker.Estimate?) {
        teacherSlide = estimate
        recordSlideChange(estimate)
        if isFollowing, let page = estimate?.page, page != currentPage {
            currentPage = page
        }
    }

    /// The student turned the page themselves: pause following until they resume. Only real input reaches
    /// here (PDFReaderView filters out PDFKit's own layout changes).
    func userTurnedPage(to page: Int) {
        currentPage = page
        if isFollowing, let teacherPage = teacherSlide?.page, page != teacherPage { followPaused = true }
    }

    func resumeFollowing() {
        followPaused = false
        if let page = teacherSlide?.page { currentPage = page }
    }

    /// Slide text for answering a detected question: the teacher's slide and its neighbours while
    /// tracking, else the page the question was asked on.
    func slideContext(for question: ClassQuestion) -> String? {
        guard let document else { return nil }
        if let tracker = slideTracker, let slide = teacherSlide?.slide {
            return tracker.context(around: slide, pageText: document.pageText)
        }
        return question.page.map { document.pageText($0 - 1) }
    }

    // MARK: Asking about a selection

    /// The reader or a caption reports what is selected (nil when nothing is); ⌘E acts on it.
    func selectionChanged(_ selection: TextSelection?) {
        if let selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeSelection = selection
        } else if selection == nil {
            activeSelection = nil
        }
    }

    /// ⌘E: explain whatever is selected, in the slides or a caption.
    func explainActiveSelection() {
        guard let activeSelection else { return }
        ask(activeSelection, action: .explain)
    }

    func ask(about selection: String, page: Int, action: SelectionAction) {
        ask(TextSelection(text: selection, source: .slide(page: page)), action: action)
    }

    func ask(_ selection: TextSelection, action: SelectionAction) {
        guard hasAPIKey else {
            errorMessage = "填写 API key 后才能提问，请到“设置”里填写。"
            return
        }
        let question: ClassQuestion
        switch selection.source {
        case .slide(let page):
            let text = (document?.repaired(selection.text) ?? selection.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // A segment id is required; slide questions hang off a fresh one so they never match a caption.
            question = ClassQuestion(segmentID: UUID(), at: elapsed, quote: String(text.prefix(2000)), english: action.question, chinese: action.question, origin: .selection, page: page)
        case .caption(let segmentID):
            let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let segment = segments.first(where: { $0.id == segmentID }) else { return }
            question = ClassQuestion(segmentID: segmentID, at: segment.start, quote: String(text.prefix(2000)), english: action.question, chinese: action.question, origin: .caption, page: slidePage(at: segment.start))
        }
        showQuestionsTab = true
        Task { await answer(question) }
    }

    /// The teacher's page (1-based) at a moment of the lecture: from the recorded timeline when reviewing,
    /// else the slide being followed now.
    func slidePage(at time: TimeInterval) -> Int? {
        if let reviewing {
            return reviewing.slides.last { $0.at <= time + 1 }?.page
        }
        return teacherSlide.map { $0.page + 1 }
    }
}
