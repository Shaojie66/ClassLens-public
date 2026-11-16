import Foundation

/// Writes one lecture into the vault according to an `ExportPlan`. Only ever creates files: writing fails
/// rather than replacing anything that appeared since the plan was made.
enum ObsidianExporter {
    struct Result: Sendable {
        var written: [URL]
        /// Set when the transcript and audio were written but the summary could not be made.
        var summaryError: String?
    }

    enum Failure: LocalizedError {
        case exists(String)

        var errorDescription: String? {
            switch self {
            case .exists(let name): "“\(name)”已经存在，没有覆盖。请重新打开导出窗口，它会改用新的文件名。"
            }
        }
    }

    static func export(
        _ session: LoadedSession,
        plan: ExportPlan,
        slidesFile: String?,
        pageText: @escaping @Sendable (Int) -> String?,
        summarizer: LectureSummarizer?,
        progress: @MainActor (String) -> Void
    ) async throws -> Result {
        let manager = FileManager.default
        for url in plan.files {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: url.path) { throw Failure.exists(url.lastPathComponent) }
        }
        var written: [URL] = []

        if plan.includeTranscript {
            await progress("正在写转写…")
            let markdown = TranscriptMarkdown(session: session, plan: plan, slidesFile: slidesFile, pageTitle: { pageText($0)?.split(whereSeparator: \.isNewline).first.map(String.init) }).render()
            try Data(markdown.utf8).write(to: plan.transcriptURL, options: .withoutOverwriting)
            written.append(plan.transcriptURL)
        }

        if plan.includeAudio, manager.fileExists(atPath: session.summary.audioURL.path) {
            await progress("正在复制录音…")
            try manager.copyItem(at: session.summary.audioURL, to: plan.audioURL)
            written.append(plan.audioURL)
        }

        var summaryError: String?
        if plan.includeSummary {
            if let summarizer {
                await progress("正在生成 AI 课后总结（大约 1 分钟）…")
                do {
                    let body = try await summarizer.summarize(session, pageText: pageText)
                    let document = LectureSummarizer.document(body: body, plan: plan, session: session, transcriptFile: plan.transcriptURL.deletingPathExtension().lastPathComponent, model: summarizer.model)
                    try Data(document.utf8).write(to: plan.summaryURL, options: .withoutOverwriting)
                    written.append(plan.summaryURL)
                } catch {
                    summaryError = error.localizedDescription
                }
            } else {
                summaryError = "没有 API key，跳过了 AI 课后总结。"
            }
        }
        return Result(written: written, summaryError: summaryError)
    }
}
