import Foundation
import Testing
@testable import ClassLens

struct GlossaryTests {
    @Test func parsesDedupesAndDropsBlanks() {
        let reply = #"""
        {"terms": [
          {"en": "null hypothesis", "zh": "原假设"},
          {"en": "Null Hypothesis", "zh": "零假设"},
          {"en": "  ", "zh": "空"},
          {"en": "H0", "zh": "H0"},
          {"en": "type I error"}
        ]}
        """#
        let terms = GlossaryExtractor.parse(reply)
        #expect(terms == [
            GlossaryTerm(english: "null hypothesis", chinese: "原假设"),
            GlossaryTerm(english: "H0", chinese: "H0"),
            GlossaryTerm(english: "type I error", chinese: ""),
        ])
        #expect(GlossaryExtractor.parse("not json").isEmpty)
    }

    @Test func formatsForRecognitionAndTranslation() {
        let glossary = Glossary(documentFingerprint: "x", terms: [
            GlossaryTerm(english: "H0", chinese: "H0"),
            GlossaryTerm(english: "statistical power", chinese: "统计功效"),
            GlossaryTerm(english: "p-value", chinese: ""),
            GlossaryTerm(english: "s", chinese: "s"),
            GlossaryTerm(english: "θ", chinese: "θ"),
        ])
        #expect(glossary.recognitionTerms == ["statistical power", "p-value", "H0", "θ"])
        #expect(glossary.translationLines == ["H0 → H0", "statistical power → 统计功效", "p-value", "s → s", "θ → θ"])
    }

    @Test func cacheRoundTrips() throws {
        let glossary = Glossary(documentFingerprint: "test-\(UUID().uuidString)", terms: [GlossaryTerm(english: "variance", chinese: "方差")])
        try GlossaryCache.save(glossary)
        defer { try? FileManager.default.removeItem(at: GlossaryCache.file(glossary.documentFingerprint)) }
        #expect(GlossaryCache.file(glossary.documentFingerprint).lastPathComponent.hasSuffix(".v\(GlossaryCache.version).json"))
        #expect(GlossaryCache.load(glossary.documentFingerprint) == glossary)
        #expect(GlossaryCache.load("missing-\(UUID().uuidString)") == nil)
    }
}

@MainActor
struct LectureDocumentTests {
    private let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/slides/hypothesis_testing.pdf")

    @Test func readsPagesAndFingerprint() throws {
        let document = try LectureDocument(url: fixture)
        #expect(document.pageCount == 6)
        #expect(document.pageText(4).contains("Type I error (false positive)"))
        #expect(document.fingerprint.count == 64)
        #expect(try LectureDocument(url: fixture).fingerprint == document.fingerprint)
        let full = document.fullText()
        #expect(full.hasPrefix("[p. 1]\nHypothesis Testing: One Population"))
        #expect(document.fullText(limit: 300).count <= 300)
    }

    /// PowerPoint's own PDF export of the sample deck, with the broken "ti" ligatures it produces.
    @Test func repairsPowerPointLigatures() throws {
        let exported = fixture.deletingLastPathComponent().appending(path: "hypothesis_testing.powerpoint-export.pdf")
        let document = try LectureDocument(url: exported)
        let raw = document.pdf.page(at: 2)?.string ?? ""
        #expect(raw.contains("Sta:s:c") || raw.contains("distribuTon"), "fixture should still show the damage")
        let page = document.pageText(2)
        #expect(page.contains("Test Statistic"))
        #expect(page.contains("t distribution"))
        #expect(page.contains("critical value, rejection region"))
        #expect(document.repaired("criTcal value") == "critical value")
    }

    @Test func rejectsNonPDF() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "not-a-pdf-\(UUID().uuidString).pdf")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: LectureDocument.Failure.self) { try LectureDocument(url: url) }
    }
}
