import Foundation
import Testing
@testable import ClassLens

struct VaultLocationTests {
    private let slides = "/Users/me/Documents/Obsidian Libraries/AI（MSc）/模块/SCEM/资料/课件/SCEM_Week7_Materials/Lecture_07/07-01 - Basic statistical inference.pdf"

    @Test func infersVaultCourseAndWeekFromTheSlidesPath() throws {
        let location = try #require(VaultLocation.infer(fromSlidesAt: slides))
        #expect(location.vaultRoot.path == "/Users/me/Documents/Obsidian Libraries/AI（MSc）")
        #expect(location.course == "SCEM")
        #expect(location.classLensFolder.path == "/Users/me/Documents/Obsidian Libraries/AI（MSc）/模块/SCEM/资料/课堂记录/ClassLens")
        #expect(VaultLocation.week(fromSlidesAt: slides) == 7)
        #expect(VaultLocation.week(fromSlidesAt: "/v/模块/AWS/资料/课件/AWS-W03-intro.pdf") == 3)
        #expect(VaultLocation.week(fromSlidesAt: "/v/模块/AWS/资料/课件/intro.pdf") == nil)
    }

    @Test func slidesOutsideAVaultHaveNoLocation() {
        #expect(VaultLocation.infer(fromSlidesAt: "/Users/me/Downloads/deck.pdf") == nil)
        #expect(VaultLocation.infer(fromSlidesAt: "/v/模块/SCEM") == nil, "the course folder itself is not a slide")
    }
}

struct ExportPlanTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let date = ISO8601DateFormatter().date(from: "2026-11-02T14:00:00Z")!

    @Test func namesFilesByCourseWeekAndDate() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ExportPlan(folder: root, course: "SCEM", week: 7, lectureDate: date, includeAudio: true, includeSummary: true)
        #expect(plan.files.map { $0.path.replacingOccurrences(of: root.path, with: "") } == [
            "/转写/SCEM-W07-2026-11-02-课堂转写.md",
            "/录音/SCEM-W07-2026-11-02-课堂录音.m4a",
            "/AI总结/SCEM-W07-2026-11-02-AI总结.md",
        ])
        #expect(!plan.isRenamed)
        let noWeek = ExportPlan(folder: root, course: "SCEM", week: nil, lectureDate: date, includeAudio: false, includeSummary: false)
        #expect(noWeek.files.map(\.lastPathComponent) == ["SCEM-2026-11-02-课堂转写.md"])
    }

    @Test func takesNumberedNamesInsteadOfOverwriting() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "录音"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: root.appending(path: "录音/SCEM-W07-2026-11-02-课堂录音.m4a"))
        let plan = ExportPlan(folder: root, course: "SCEM", week: 7, lectureDate: date, includeAudio: true, includeSummary: false)
        #expect(plan.isRenamed)
        #expect(plan.transcriptURL.lastPathComponent == "SCEM-W07-2026-11-02-2-课堂转写.md")
        #expect(plan.audioURL.lastPathComponent == "SCEM-W07-2026-11-02-2-课堂录音.m4a")
    }
}

struct TranscriptMarkdownTests {
    static func session(directory: URL = URL(fileURLWithPath: "/tmp/none")) -> LoadedSession {
        var meta = SessionMeta(id: UUID(), createdAt: ISO8601DateFormatter().date(from: "2026-11-02T14:00:00Z")!, source: "microphone", engine: "Qwen3-ASR 1.7B")
        meta.duration = 6749
        meta.document = SessionMeta.Document(name: "07-01 - Basic statistical inference", sourcePath: "/v/模块/SCEM/资料/课件/07-01 - Basic statistical inference.pdf", pdfPath: "/v/x.pdf", fingerprint: "f")
        let first = TranscriptSegment(start: 58, end: 62, text: "Today we cover hypotheses.", isFinal: true, translation: "今天讲假设。")
        let second = TranscriptSegment(start: 5822, end: 5830, text: "Where is the probability\nunder the green curve?", isFinal: true, translation: "在绿色曲线下的哪里？")
        let question = ClassQuestion(segmentID: second.id, at: 5822, quote: "Where is the probability under the green curve?", english: "Where is it?", chinese: "这个概率在图上的哪里？", origin: .detected, page: 54, status: .answered, answer: "**答案**：两条红线之间。")
        let selection = ClassQuestion(segmentID: UUID(), at: 10, quote: "β = P(fail to reject H0 | H0 is false)", english: "解释", chinese: "请解释这段内容的意思", origin: .selection, page: 54, status: .answered, answer: "β 是第二类错误的概率。")
        let summary = SessionSummary(directory: directory, meta: meta, duration: 6749, questionCount: 2)
        return LoadedSession(summary: summary, segments: [first, second], questions: [question, selection], slides: [
            SlideMark(at: 50, slide: 2, page: 2, confidence: 0.9),
            SlideMark(at: 5800, slide: 22, page: 54, confidence: 0.75),
        ])
    }

    private func render(includeAudio: Bool = true) -> String {
        let plan = ExportPlan(folder: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"), course: "SCEM", week: 7, lectureDate: Self.session().summary.meta.createdAt, includeAudio: includeAudio, includeSummary: true)
        return TranscriptMarkdown(session: Self.session(), plan: plan, slidesFile: "07-01 - Basic statistical inference.pdf", pageTitle: { $0 == 54 ? "Type II errors" : ($0 == 2 ? "In this lecture..." : nil) }, created: ISO8601DateFormatter().date(from: "2026-11-03T09:00:00Z")!).render()
    }

    @Test func frontmatterHasTheVaultFields() {
        let text = render()
        #expect(text.hasPrefix("---\ntitle: SCEM W07 课堂转写 2026-11-02 · 07-01 - Basic statistical inference\ncourse: SCEM\nweek: W07\ntype: 课堂记录\n"))
        for key in ["tags:", "source:", "confidence: low", "created: 2026-11-03", "updated: 2026-11-03", "lecture_date: 2026-11-02", "duration: \"1:52:29\"", "slides: \"[[07-01 - Basic statistical inference.pdf]]\"", "audio: \"[[SCEM-W07-2026-11-02-课堂录音.m4a]]\""] {
            #expect(text.contains("\n" + key), "\(key)")
        }
        #expect(text.contains("> [!warning] 资料范围与可靠度：low（二手，需核对）"))
    }

    @Test func groupsTheTranscriptBySlideWithPageLinks() {
        let text = render()
        #expect(text.contains("## 逐段转写（按课件页）"))
        #expect(text.contains("### 第 2 页 · In this lecture...（[[07-01 - Basic statistical inference.pdf#page=2|课件第 2 页]]）\n\n- `00:58` Today we cover hypotheses.\n  今天讲假设。"))
        #expect(text.contains("### 第 54 页 · Type II errors"))
        #expect(text.contains("- `1:37:02` Where is the probability under the green curve?\n  在绿色曲线下的哪里？"), "newlines in a caption are joined")
    }

    @Test func listsQuestionsWithQuotesAndAnswers() {
        let text = render()
        #expect(text.contains("## 老师提问与参考答案\n\n### 1. [1:37:02] 这个概率在图上的哪里？\n\n> [!quote] 老师原话\n> Where is the probability under the green curve?"))
        #expect(text.contains("**参考答案（AI 生成，需核对）**\n\n**答案**：两条红线之间。"))
        #expect(text.contains("## 划词提问\n\n### 课件划词：请解释这段内容的意思"))
        #expect(text.contains("| 老师提问 | 1 个 |"))
        #expect(!render(includeAudio: false).contains("audio:"))
        #expect(TranscriptMarkdown.duration(120) == "0:02:00")
        #expect(TranscriptMarkdown.oneLine("unknown 𝝈𝟐") == "unknown σ2")
        #expect(TranscriptMarkdown.oneLine("在哪里？（第一类：α）") == "在哪里？（第一类：α）", "Chinese punctuation stays full-width")
    }
}

struct ObsidianExporterTests {
    @Test func writesNewFilesAndNeverOverwrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessionDirectory = root.appending(path: "session", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fake audio".utf8).write(to: sessionDirectory.appending(path: "audio.m4a"))
        let session = TranscriptMarkdownTests.session(directory: sessionDirectory)
        let folder = root.appending(path: "ClassLens", directoryHint: .isDirectory)
        let plan = ExportPlan(folder: folder, course: "SCEM", week: 7, lectureDate: session.summary.meta.createdAt, includeAudio: true, includeSummary: true)

        let result = try await ObsidianExporter.export(session, plan: plan, slidesFile: nil, pageText: { _ in nil }, summarizer: nil) { _ in }
        #expect(result.written == [plan.transcriptURL, plan.audioURL])
        #expect(result.summaryError != nil, "no key: the summary is skipped and said so")
        #expect(try String(contentsOf: plan.transcriptURL, encoding: .utf8).contains("## 逐段转写"))
        #expect(try Data(contentsOf: plan.audioURL) == Data("fake audio".utf8))

        // Same plan again: the files exist now, so it refuses instead of replacing them.
        await #expect(throws: ObsidianExporter.Failure.self) {
            try await ObsidianExporter.export(session, plan: plan, slidesFile: nil, pageText: { _ in nil }, summarizer: nil) { _ in }
        }
        // Adding only the summary next to that export keeps the original names.
        let summaryOnly = ExportPlan(folder: folder, course: "SCEM", week: 7, lectureDate: session.summary.meta.createdAt, includeTranscript: false, includeAudio: false, includeSummary: true)
        #expect(!summaryOnly.isRenamed)
        #expect(summaryOnly.files == [plan.summaryURL])
        // A fresh plan moves to numbered names.
        let next = ExportPlan(folder: folder, course: "SCEM", week: 7, lectureDate: session.summary.meta.createdAt, includeAudio: true, includeSummary: false)
        #expect(next.transcriptURL.lastPathComponent == "SCEM-W07-2026-11-02-2-课堂转写.md")
    }

    @Test func summaryFileGetsFrontmatterAndCalloutFromTheApp() {
        let plan = ExportPlan(folder: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"), course: "SCEM", week: 7, lectureDate: TranscriptMarkdownTests.session().summary.meta.createdAt, includeAudio: false, includeSummary: true)
        let text = LectureSummarizer.document(body: "## 核心脉络\n\n本节课讲假设检验。", plan: plan, session: TranscriptMarkdownTests.session(), transcriptFile: "SCEM-W07-2026-11-02-课堂转写", model: "deepseek-v4-pro")
        #expect(text.hasPrefix("---\ntitle: SCEM W07 AI 课后总结 2026-11-02\ncourse: SCEM\nweek: W07\ntype: AI总结\n"))
        #expect(text.contains("confidence: low"))
        #expect(text.contains("transcript: \"[[SCEM-W07-2026-11-02-课堂转写]]\""))
        #expect(text.contains("> [!warning] 资料范围与可靠度：low（二手，需核对）"))
        #expect(text.hasSuffix("## 核心脉络\n\n本节课讲假设检验。\n"))
    }
}
