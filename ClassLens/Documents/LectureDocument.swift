import CryptoKit
import Foundation
import PDFKit

/// An open slide deck or reading. PPT files are converted to PDF before they get here (M5).
@MainActor
final class LectureDocument {
    let url: URL
    let pdf: PDFDocument
    /// SHA-256 of the file, so a glossary is extracted once per document however it is named.
    let fingerprint: String

    enum Failure: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "无法打开“\(name)”，它可能不是有效的 PDF，或者已加密。"
            }
        }
    }

    /// The file the student opened, when it was converted from PowerPoint or Keynote.
    let sourceURL: URL?

    init(url: URL, source: URL? = nil) throws {
        let data = try Data(contentsOf: url)
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0, !pdf.isLocked else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        self.url = url
        self.sourceURL = source
        self.pdf = pdf
        self.fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var name: String { (sourceURL ?? url).deletingPathExtension().lastPathComponent }
    var pageCount: Int { pdf.pageCount }

    /// Words used anywhere in the document, so ligature damage can be repaired against its own terms.
    private lazy var vocabulary: Set<String> = {
        LigatureRepair.vocabulary(of: (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: " "))
    }()

    /// Text of one page (0-based), whitespace tidied and broken "ti" ligatures repaired.
    func pageText(_ index: Int) -> String {
        guard let page = pdf.page(at: index) else { return "" }
        let raw = (page.string ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return repaired(raw)
    }

    /// Repairs text taken from this document, such as a selection in the reader.
    func repaired(_ text: String) -> String {
        LigatureRepair.repair(text, knownWords: vocabulary)
    }

    /// All pages as "[p. n] text", cut at `limit` characters, for glossary extraction.
    func fullText(limit: Int = 24_000) -> String {
        var result = ""
        for index in 0..<pageCount {
            let page = "[p. \(index + 1)]\n" + pageText(index) + "\n\n"
            if result.count + page.count > limit { break }
            result += page
        }
        return result
    }
}
