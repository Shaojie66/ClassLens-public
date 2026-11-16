import Foundation
import Testing
@testable import ClassLens

struct SessionLibraryTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func savesListsAndLoadsALecture() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = SessionMeta.Document(name: "07-01 Basic statistical inference", sourcePath: "/x/deck.pptx", pdfPath: "/x/deck.pdf", fingerprint: "abc")
        let store = try SessionStore(source: "microphone", engine: "test", document: document, root: root)
        var segment = TranscriptSegment(start: 1, end: 4, text: "The null hypothesis.", isFinal: true)
        try await store.append(segment)
        segment.translation = "原假设。"
        try await store.append(segment)
        try await store.appendSlide(SlideMark(at: 4, slide: 6, page: 7, confidence: 0.9))
        try await store.writeQuestions([ClassQuestion(segmentID: segment.id, at: 1, quote: "q", english: "Why?", chinese: "为什么？", origin: .detected)])
        try await store.close(duration: 3600)

        let list = SessionLibrary.list(root: root)
        #expect(list.count == 1)
        let summary = try #require(list.first)
        #expect(summary.duration == 3600)
        #expect(summary.questionCount == 1)
        #expect(summary.title.hasPrefix("07-01 Basic statistical inference · "))
        #expect(summary.meta.endedAt != nil)

        let loaded = try SessionLibrary.load(summary)
        #expect(loaded.segments.map(\.translation) == ["原假设。"])
        #expect(loaded.slides == [SlideMark(at: 4, slide: 6, page: 7, confidence: 0.9)])
        #expect(loaded.questions.first?.chinese == "为什么？")

        let renamed = try SessionLibrary.rename(summary, to: "  Week 7 · 假设检验  ")
        #expect(renamed.title == "Week 7 · 假设检验")
        #expect(SessionLibrary.list(root: root).first?.title == "Week 7 · 假设检验")
    }

    @Test func readsSessionsRecordedBeforeM6() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // meta.json exactly as M1–M5 wrote it: no title, duration or document.
        try Data(#"{"createdAt":"2026-11-02T16:38:00Z","engine":"Qwen3-ASR 1.7B","id":"\#(UUID().uuidString)","source":"replay:lecture.wav"}"#.utf8)
            .write(to: directory.appending(path: "meta.json"))
        let line = try JSONEncoder().encode(TranscriptSegment(start: 590, end: 600, text: "Last line.", isFinal: true))
        try (String(decoding: line, as: UTF8.self) + "\n").write(to: directory.appending(path: "transcript.jsonl"), atomically: true, encoding: .utf8)

        let summary = try #require(SessionLibrary.list(root: root).first)
        #expect(summary.duration == 600, "falls back to the last caption")
        #expect(summary.meta.isReplay)
        #expect(summary.title.hasPrefix("回放 · "))
        #expect(try SessionLibrary.load(summary).slides.isEmpty)
    }

    @MainActor
    @Test func questionsAskedWhileReviewingAreSavedToThatLecture() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(source: "microphone", engine: "test", root: root)
        try await store.close(duration: 60)
        let summary = try #require(SessionLibrary.list(root: root).first)
        let model = AppModel()
        model.reviewing = try SessionLibrary.load(summary)
        model.questions = [ClassQuestion(segmentID: UUID(), at: 3, quote: "estimation", english: "解释", chinese: "解释", origin: .caption)]
        await model.saveQuestions()
        #expect(try SessionLibrary.load(summary).questions.map(\.quote) == ["estimation"])
        #expect(model.reviewing?.questions.count == 1)
    }

    @Test func skipsFoldersWithoutMeta() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "junk"), withIntermediateDirectories: true)
        #expect(SessionLibrary.list(root: root).isEmpty)
    }
}
