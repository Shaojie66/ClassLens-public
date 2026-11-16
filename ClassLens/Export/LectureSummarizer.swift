import Foundation

/// Writes the after-class summary with the strong model from the whole transcript.
struct LectureSummarizer: Sendable {
    let client: any LLMClient
    let model: String

    func summarize(_ session: LoadedSession, pageText: @Sendable (Int) -> String?) async throws -> String {
        let marks = session.slides
        let transcript = session.segments.map { segment in
            let page = marks.last { $0.at <= segment.start + 1 }?.page
            return "[\(TranscriptMarkdown.clock(segment.start))]" + (page.map { " (p.\($0))" } ?? "") + " " + TranscriptMarkdown.oneLine(segment.text)
        }.joined(separator: "\n")
        let pages = Set(marks.map(\.page)).sorted()
        let slides = pages.compactMap { page in pageText(page).map { "[第 \(page) 页]\n\($0)" } }.joined(separator: "\n\n")
        let questions = session.questions.map { "[\(TranscriptMarkdown.clock($0.at))] \($0.english)" }.joined(separator: "\n")
        // Streamed: a whole lecture is ~35k tokens in and several thousand out, and a non-streamed request
        // sits silent long enough to hit the connection's idle timeout.
        var text = ""
        for try await piece in client.stream(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: SummaryPrompts.system),
                ChatMessage(role: .user, content: SummaryPrompts.user(transcript: transcript, slides: slides, questions: questions)),
            ],
            temperature: 0.3,
            // The Week 7 summary with its 待核对 list ran past 6000 tokens and was cut off mid-line.
            maxTokens: 12000
        )) {
            text += piece
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMFailure.emptyReply }
        return SummaryNumberCheck.annotate(text, segments: session.segments, slides: slides)
    }

    /// The summary file: frontmatter and the reliability callout are written here, never by the model.
    static func document(body: String, plan: ExportPlan, session: LoadedSession, transcriptFile: String, model: String, created: Date = .now) -> String {
        let title = [plan.course, plan.weekText, "AI 课后总结", plan.dateText].compactMap { $0 }.joined(separator: " ")
        var lines = [
            "---",
            "title: \(TranscriptMarkdown.yaml(title))",
            "course: \(TranscriptMarkdown.yaml(plan.course))",
        ]
        if let week = plan.weekText { lines.append("week: \(week)") }
        lines += [
            "type: AI总结",
            "tags:",
            "  - \(TranscriptMarkdown.yaml(plan.course))",
            "  - 课堂记录",
            "  - AI总结",
            "source: \(TranscriptMarkdown.yaml("ClassLens AI 课后总结（\(model)），依据机器转写与课件"))",
            "confidence: low",
            "created: \(TranscriptMarkdown.day(created))",
            "updated: \(TranscriptMarkdown.day(created))",
            "lecture_date: \(plan.dateText)",
            "transcript: \(TranscriptMarkdown.yaml("[[\(transcriptFile)]]"))",
            "---",
            "",
            "# \(title)",
            "",
            "> [!warning] 资料范围与可靠度：low（二手，需核对）",
            "> 由 AI 根据机器转写和课件自动生成，转写本身可能有识别错误，总结可能遗漏或误解老师的意思。时间点可以回到 [[\(transcriptFile)]] 和录音核对；以官方课件为准。",
            "",
            body.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
