import Foundation
import Testing
@testable import ClassLens

@MainActor
struct SelectionAskTests {
    private func model(captions count: Int) -> (AppModel, [TranscriptSegment]) {
        let model = AppModel()
        let segments = (0..<count).map { TranscriptSegment(start: Double($0) * 5, end: Double($0) * 5 + 4, text: "Line \($0).", isFinal: true) }
        model.segments = segments
        return (model, segments)
    }

    @Test func studentsCaptionQuestionsDoNotMarkTheTeacherAsAsking() {
        let (model, segments) = model(captions: 3)
        model.questions = [ClassQuestion(segmentID: segments[1].id, at: 5, quote: "Line", english: "解释", chinese: "解释", origin: .caption)]
        #expect(!model.isQuestion(segments[1].id))
        model.questions.append(ClassQuestion(segmentID: segments[2].id, at: 10, quote: "Why?", english: "Why?", chinese: "为什么？", origin: .detected))
        #expect(model.isQuestion(segments[2].id))
    }

    @Test func captionContextIsFiveLinesEachSide() {
        let (model, segments) = model(captions: 20)
        let context = model.captionContext(around: segments[10].id)
        #expect(context.count == 11)
        #expect(context.first == "[0:25] Line 5.")
        #expect(context.last == "[1:15] Line 15.")
        #expect(model.captionContext(around: segments[0].id).count == 6)
    }

    @Test func pageAtAMomentComesFromTheRecordedTimelineWhenReviewing() throws {
        let (model, segments) = model(captions: 3)
        var meta = SessionMeta(id: UUID(), createdAt: .now, source: "microphone", engine: "test")
        meta.duration = 15
        model.reviewing = LoadedSession(summary: SessionSummary(directory: URL(fileURLWithPath: "/tmp"), meta: meta, duration: 15, questionCount: 0), segments: segments, questions: [], slides: [
            SlideMark(at: 0, slide: 1, page: 1, confidence: 0.5),
            SlideMark(at: 8, slide: 22, page: 54, confidence: 0.8),
        ])
        #expect(model.slidePage(at: 2) == 1)
        #expect(model.slidePage(at: 10) == 54)
    }

    @Test func clearingTheSelectionDisablesCommandE() {
        let (model, segments) = model(captions: 1)
        model.selectionChanged(TextSelection(text: "Line", source: .caption(segmentID: segments[0].id)))
        #expect(model.activeSelection?.text == "Line")
        model.selectionChanged(TextSelection(text: "   ", source: .slide(page: 3)))
        #expect(model.activeSelection?.text == "Line", "blank selections are ignored")
        model.selectionChanged(nil)
        #expect(model.activeSelection == nil)
    }

    @Test func captionPromptCarriesTheSentenceAndTranslation() {
        let prompt = QuestionPrompts.captionUser(question: "解释", selection: "fail to reject", sentence: "We fail to reject the null.", translation: "我们不拒绝原假设。", around: ["[1:00] Earlier."], slide: "Type II errors", glossary: ["null hypothesis → 原假设"])
        #expect(prompt.contains("老师当时讲的课件页：\nType II errors"))
        #expect(prompt.contains("学生选中内容所在的那句：\nWe fail to reject the null.\n（机器翻译：我们不拒绝原假设。）"))
        #expect(prompt.hasSuffix("学生选中的内容：fail to reject\n\n学生的问题：解释"))
        #expect(QuestionPrompts.captionSystem.contains("grass"))
    }
}
