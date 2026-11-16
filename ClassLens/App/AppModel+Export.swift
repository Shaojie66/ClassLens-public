import AppKit
import Foundation

enum ExportState: Equatable {
    case idle
    case running(String)
    case done([URL], summaryError: String?)
    case failed(String)
}

extension AppModel {
    /// Where the export goes by default: the vault folder inferred from the lecture's slides.
    func defaultExportLocation(for session: LoadedSession) -> VaultLocation? {
        guard let record = session.summary.meta.document else { return nil }
        return VaultLocation.infer(fromSlidesAt: record.sourcePath ?? record.pdfPath)
    }

    func defaultWeek(for session: LoadedSession) -> Int? {
        guard let record = session.summary.meta.document else { return nil }
        return VaultLocation.week(fromSlidesAt: record.sourcePath ?? record.pdfPath)
    }

    /// Exports a reviewed lecture; `plan` comes from the export sheet (or the command line).
    func export(_ session: LoadedSession, plan: ExportPlan) async {
        exportState = .running("准备导出…")
        let record = session.summary.meta.document
        // Page links only work for PDFs that live in the vault; a converted PPT is linked by name only.
        let source = record?.sourcePath.map { URL(fileURLWithPath: $0) }
        let slidesFile = source.flatMap { $0.pathExtension.lowercased() == "pdf" ? $0.lastPathComponent : nil }
        let pages: [String] = document.map { document in (0..<document.pageCount).map(document.pageText) } ?? []
        let pageText: @Sendable (Int) -> String? = { page in pages.indices.contains(page - 1) ? pages[page - 1] : nil }
        let summarizer = plan.includeSummary ? (try? provider.loadClient()).map { LectureSummarizer(client: $0, model: provider.strongModel) } : nil
        do {
            let result = try await ObsidianExporter.export(session, plan: plan, slidesFile: slidesFile, pageText: pageText, summarizer: summarizer) { [weak self] step in
                self?.exportState = .running(step)
            }
            exportState = .done(result.written, summaryError: result.summaryError)
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    func revealExport(_ files: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// Opens the transcript in Obsidian (obsidian://open?path=…), if Obsidian is installed.
    func openInObsidian(_ file: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: file.path)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
