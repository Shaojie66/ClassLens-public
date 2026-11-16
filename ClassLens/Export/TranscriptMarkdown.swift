import Foundation

/// The class record as Markdown in the student's vault style (AI协作规则 §4): frontmatter, a reliability
/// callout, the teacher's questions with AI answers, questions about slides, and the transcript grouped by
/// the slide the teacher was on.
struct TranscriptMarkdown {
    var session: LoadedSession
    var plan: ExportPlan
    /// File name of the slides PDF for wiki links, when the lecture had slides.
    var slidesFile: String?
    /// Title of a 1-based page, for section headings.
    var pageTitle: (Int) -> String?
    var created: Date = .now

    func render() -> String {
        [frontmatter(), heading(), reliability(), overview(), teacherQuestions(), selectionQuestions(), transcript()]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n") + "\n"
    }

    // MARK: Parts

    private var title: String {
        let base = [plan.course, plan.weekText, "课堂转写", plan.dateText].compactMap { $0 }.joined(separator: " ")
        return session.summary.meta.document.map { "\(base) · \($0.name)" } ?? base
    }

    private func frontmatter() -> String {
        var lines = [
            "---",
            "title: \(Self.yaml(title))",
            "course: \(Self.yaml(plan.course))",
        ]
        if let week = plan.weekText { lines.append("week: \(week)") }
        lines += [
            "type: 课堂记录",
            "tags:",
            "  - \(Self.yaml(plan.course))",
            "  - 课堂记录",
            "  - ClassLens",
            "source: \(Self.yaml("ClassLens 机器转写（\(session.summary.meta.engine)），中文翻译与参考答案由 DeepSeek 生成"))",
            "confidence: low",
            "created: \(Self.day(created))",
            "updated: \(Self.day(created))",
            "lecture_date: \(plan.dateText)",
            "duration: \(Self.yaml(Self.duration(session.summary.duration)))",
        ]
        if let slidesFile { lines.append("slides: \(Self.yaml("[[\(slidesFile)]]"))") }
        if plan.includeAudio { lines.append("audio: \(Self.yaml("[[\(plan.audioURL.lastPathComponent)]]"))") }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private func heading() -> String {
        "# \(title)"
    }

    private func reliability() -> String {
        """
        > [!warning] 资料范围与可靠度：low（二手，需核对）
        > 英文是 ClassLens 本地语音识别的结果，可能听错术语或漏句；中文是机器翻译；“参考答案”由 AI 生成，未经老师确认；课件页码是程序根据讲课内容自动判断的，可能差一页。引用前请对照录音和课件核对。
        """
    }

    private func overview() -> String {
        var rows = [
            "| 项目 | 内容 |",
            "|---|---|",
            "| 上课日期 | \(plan.dateText) |",
            "| 时长 | \(Self.duration(session.summary.duration)) |",
        ]
        if let slidesFile { rows.append("| 课件 | [[\(slidesFile)]] |") }
        if plan.includeAudio { rows.append("| 录音 | [[\(plan.audioURL.lastPathComponent)]] |") }
        if plan.includeSummary { rows.append("| AI 课后总结 | [[\(plan.summaryURL.deletingPathExtension().lastPathComponent)]] |") }
        rows.append("| 老师提问 | \(teacherAsked.count) 个 |")
        rows.append("| 字幕 | \(session.segments.count) 句 |")
        return "## 概况\n\n" + rows.joined(separator: "\n")
    }

    private var teacherAsked: [ClassQuestion] { session.questions.filter { $0.origin.isTeachers } }

    private func teacherQuestions() -> String {
        guard !teacherAsked.isEmpty else { return "" }
        let items = teacherAsked.enumerated().map { index, question in
            var block = "### \(index + 1). [\(Self.clock(question.at))] \(question.chinese.isEmpty ? question.english : question.chinese)"
            if question.origin == .manual { block += "（手动标记）" }
            block += "\n\n> [!quote] 老师原话\n> \(Self.oneLine(question.quote))"
            if let link = pageLink(question.page) { block += "\n\n相关课件：\(link)" }
            block += "\n\n**参考答案（AI 生成，需核对）**\n\n" + answer(question)
            return block
        }
        return "## 老师提问与参考答案\n\n" + items.joined(separator: "\n\n")
    }

    private func selectionQuestions() -> String {
        let asked = session.questions.filter { !$0.origin.isTeachers }
        guard !asked.isEmpty else { return "" }
        let items = asked.map { question in
            var block = question.origin == .caption
                ? "### [\(Self.clock(question.at))] 字幕划词：\(question.chinese)"
                : "### 课件划词：\(question.chinese)"
            if let link = pageLink(question.page) { block += "\n\n课件：\(link)" }
            block += "\n\n> [!quote] 选中的内容\n" + question.quote.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
            block += "\n\n**AI 回答（需核对）**\n\n" + answer(question)
            return block
        }
        return "## 划词提问\n\n" + items.joined(separator: "\n\n")
    }

    private func answer(_ question: ClassQuestion) -> String {
        if let error = question.error { return "（没有生成答案：\(error)）" }
        return question.answer.isEmpty ? "（没有生成答案）" : question.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcript() -> String {
        guard !session.segments.isEmpty else { return "## 逐段转写\n\n（这节课没有字幕）" }
        var sections: [String] = []
        var currentPage: Int?? = .none
        var lines: [String] = []
        func flush() {
            guard !lines.isEmpty else { return }
            let header: String
            switch currentPage {
            case .some(.some(let page)): header = "### 第 \(page) 页" + (pageTitle(page).map { " · \(Self.oneLine($0))" } ?? "") + (pageLink(page).map { "（\($0)）" } ?? "")
            default: header = "### 未对应到课件页"
            }
            sections.append(header + "\n\n" + lines.joined(separator: "\n"))
            lines = []
        }
        let marks = session.slides
        for segment in session.segments {
            let page = marks.last { $0.at <= segment.start + 1 }?.page
            if marks.isEmpty {
                currentPage = .some(nil)
            } else if currentPage != .some(page) {
                flush()
                currentPage = .some(page)
            }
            var line = "- `\(Self.clock(segment.start))` \(Self.oneLine(segment.text))"
            if let chinese = segment.translation, !chinese.isEmpty { line += "\n  \(Self.oneLine(chinese))" }
            lines.append(line)
        }
        if marks.isEmpty {
            return "## 逐段转写\n\n" + lines.joined(separator: "\n")
        }
        flush()
        return "## 逐段转写（按课件页）\n\n" + sections.joined(separator: "\n\n")
    }

    private func pageLink(_ page: Int?) -> String? {
        guard let page, let slidesFile else { return nil }
        return "[[\(slidesFile)#page=\(page)|课件第 \(page) 页]]"
    }

    // MARK: Formatting

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Always h:mm:ss, so two minutes can't be read as two hours.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    /// A YAML scalar, quoted when it could be misread.
    static func yaml(_ text: String) -> String {
        let plain = text.allSatisfy { !":#[]{},&*!|>'\"%@`".contains($0) } && !text.hasPrefix(" ") && !text.isEmpty
        return plain ? text : "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// One line, with mathematical alphanumerics (𝝈𝟐 from slide fonts) turned into plain characters (σ2).
    /// Only that Unicode block is mapped: full compatibility mapping would also turn Chinese full-width
    /// punctuation (？（：) into ASCII.
    static func oneLine(_ text: String) -> String {
        var plain = ""
        for scalar in text.unicodeScalars {
            if (0x1D400...0x1D7FF).contains(scalar.value) {
                plain += String(scalar).precomposedStringWithCompatibilityMapping
            } else {
                plain.unicodeScalars.append(scalar)
            }
        }
        return plain.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
