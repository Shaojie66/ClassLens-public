import CryptoKit
import Foundation
import Testing
@testable import ClassLens

@MainActor
struct SlideConverterTests {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/slides")

    @Test func opensSlidesAndPDFOnly() {
        for name in ["a.pdf", "a.PPTX", "a.ppt", "a.key", "a.ppsx"] {
            #expect(AppModel.canOpen(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.docx", "a.png", "a"] {
            #expect(!AppModel.canOpen(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func cachedConversionIsReusedWithoutAnyApp() async throws {
        // A copy with a unique byte so its fingerprint can't collide with a real conversion.
        let source = FileManager.default.temporaryDirectory.appending(path: "deck-\(UUID().uuidString).pptx")
        var data = try Data(contentsOf: fixtures.appending(path: "hypothesis_testing.pptx"))
        data.append(contentsOf: Array(UUID().uuidString.utf8))
        try data.write(to: source)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let cached = SlideConverter.cacheDirectory.appending(path: "\(fingerprint).pdf")
        try FileManager.default.createDirectory(at: SlideConverter.cacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "hypothesis_testing.pdf"), to: cached)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cached)
        }

        var asked: [String] = []
        let pdf = try await SlideConverter.pdf(for: source) { asked.append($0) }
        #expect(pdf == cached)
        #expect(asked.isEmpty)
        let document = try LectureDocument(url: pdf, source: source)
        #expect(document.name.hasPrefix("deck-"))
        #expect(document.pageCount == 6)
    }

    @Test func scriptsTakeTheirPathsAsArguments() {
        for exporter in SlideConverter.Exporter.allCases {
            #expect(exporter.script.contains("item 1 of argv"))
            #expect(exporter.script.contains("item 2 of argv"))
            #expect(exporter.script.contains("if not wasRunning then"))
            #expect(exporter.script.contains("quit saving no"))
        }
    }
}
