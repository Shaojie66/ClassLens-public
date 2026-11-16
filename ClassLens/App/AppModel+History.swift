import AVFoundation
import Foundation

extension AppModel {
    // MARK: Recording the session's slides

    /// How the open slides are recorded in a session's meta.
    var documentRecord: SessionMeta.Document? {
        document.map {
            SessionMeta.Document(name: $0.name, sourcePath: ($0.sourceURL ?? $0.url).path, pdfPath: $0.url.path, fingerprint: $0.fingerprint)
        }
    }

    /// Adds a line to `slides.jsonl` when the teacher's slide changes during a recording.
    func recordSlideChange(_ estimate: SlideTracker.Estimate?) {
        guard isListening, let estimate, let store, estimate.slide != lastRecordedSlide else { return }
        lastRecordedSlide = estimate.slide
        let mark = SlideMark(at: segments.last(where: \.isFinal)?.end ?? elapsed, slide: estimate.slide + 1, page: estimate.page + 1, confidence: estimate.probability)
        Task {
            do { try await store.appendSlide(mark) } catch { errorMessage = "换页记录保存失败：\(error.localizedDescription)" }
        }
    }

    // MARK: History

    func refreshHistory() {
        history = SessionLibrary.list()
    }

    /// Shows a past lecture: its captions, questions and slides, ready to play back.
    func review(_ summary: SessionSummary) async {
        guard activity == .idle else {
            errorMessage = "正在录音，录完再回看以前的课。"
            return
        }
        stopPlayback()
        do {
            let loaded = try SessionLibrary.load(summary)
            reviewing = loaded
            segments = loaded.segments
            questions = loaded.questions
            unseenQuestions = 0
            teacherSlide = nil
            if let record = summary.meta.document {
                await openRecordedDocument(record)
            }
            player = try? AVAudioPlayer(contentsOf: summary.audioURL)
            player?.prepareToPlay()
            playbackTime = 0
            followRecordedSlides()
        } catch {
            errorMessage = "打不开这节课：\(error.localizedDescription)"
        }
    }

    /// Back to the live view, empty and ready to record.
    func leaveReview() {
        stopPlayback()
        player = nil
        reviewing = nil
        segments = []
        questions = []
        teacherSlide = nil
    }

    func rename(_ summary: SessionSummary, to title: String) {
        do {
            let renamed = try SessionLibrary.rename(summary, to: title)
            if reviewing?.summary.id == summary.id { reviewing?.summary = renamed }
            refreshHistory()
        } catch {
            errorMessage = "改名失败：\(error.localizedDescription)"
        }
    }

    func delete(_ summary: SessionSummary) {
        if reviewing?.summary.id == summary.id { leaveReview() }
        do {
            try SessionLibrary.delete(summary)
            refreshHistory()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func openRecordedDocument(_ record: SessionMeta.Document) async {
        let pdf = URL(fileURLWithPath: record.pdfPath)
        if document?.fingerprint == record.fingerprint { return }
        if FileManager.default.fileExists(atPath: pdf.path) {
            do {
                document = try LectureDocument(url: pdf, source: record.sourcePath.map { URL(fileURLWithPath: $0) })
                currentPage = 0
                slideTracker = nil
                slideLocator = nil
                glossary = GlossaryCache.load(record.fingerprint)
                glossaryState = glossary.map { .ready($0.terms.count) } ?? .none
            } catch {
                errorMessage = error.localizedDescription
            }
        } else if let source = record.sourcePath, FileManager.default.fileExists(atPath: source) {
            await openDocument(URL(fileURLWithPath: source))
        }
    }

    // MARK: Playback

    var isPlaying: Bool { playing }

    func play(from time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, time - 0.3)
        player.play()
        playing = true
        startPlaybackClock()
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            stopPlayback()
        } else {
            player.play()
            playing = true
            startPlaybackClock()
        }
    }

    func stopPlayback() {
        player?.pause()
        playbackClock?.cancel()
        playbackClock = nil
        playing = false
        playbackTime = player?.currentTime ?? playbackTime
    }

    private func startPlaybackClock() {
        playbackClock?.cancel()
        playbackClock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.playbackTime = player.currentTime
                self.followRecordedSlides()
                if !player.isPlaying {
                    self.playing = false
                    self.playbackClock = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// While reviewing, the slide recorded for the playback position, so the reader turns with the audio.
    private func followRecordedSlides() {
        guard let reviewing, let mark = reviewing.slides.last(where: { $0.at <= max(playbackTime, 0) }) ?? reviewing.slides.first else { return }
        let page = mark.page - 1
        teacherSlide = SlideTracker.Estimate(slide: mark.slide - 1, pages: page...page, probability: mark.confidence)
        if isFollowing, let document, page < document.pageCount, page != currentPage { currentPage = page }
    }
}
