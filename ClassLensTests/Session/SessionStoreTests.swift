import Foundation
import Testing
@testable import ClassLens

struct SessionStoreTests {
    @Test func transcriptKeepsLatestVersionInOrder() throws {
        let first = TranscriptSegment(start: 0, end: 2, text: "First.", isFinal: true)
        let second = TranscriptSegment(start: 2, end: 4, text: "Second.", isFinal: true)
        var translated = first
        translated.translation = "第一句。"
        let encoder = JSONEncoder()
        let lines = try [first, second, translated].map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try SessionStore.loadTranscript(url)
        #expect(loaded.map(\.text) == ["First.", "Second."])
        #expect(loaded[0].translation == "第一句。")
    }
}
