import Foundation

/// `meta.json` of a session. Fields after `engine` were added in M6 and are optional, so sessions
/// recorded earlier load unchanged.
struct SessionMeta: Codable, Sendable, Equatable {
    struct Document: Codable, Sendable, Equatable {
        /// Name shown to the student (the original PPT name for converted decks).
        var name: String
        /// The file the student opened (PPT or PDF).
        var sourcePath: String?
        /// The PDF actually shown; for PPT, the converted copy in the app's cache.
        var pdfPath: String
        var fingerprint: String
    }

    var id: UUID
    var createdAt: Date
    /// "microphone" or "replay:<file name>".
    var source: String
    var engine: String
    var title: String?
    var endedAt: Date?
    /// Seconds of audio recorded.
    var duration: TimeInterval?
    var document: Document?

    var isReplay: Bool { source.hasPrefix("replay:") }

    static func load(from directory: URL) throws -> SessionMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionMeta.self, from: Data(contentsOf: directory.appending(path: "meta.json")))
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: "meta.json"), options: .atomic)
    }
}

/// One line of `slides.jsonl`: from `at` seconds the teacher was on this slide.
struct SlideMark: Codable, Sendable, Equatable {
    var at: TimeInterval
    /// 1-based slide (group of build pages) and the 1-based page shown for it.
    var slide: Int
    var page: Int
    var confidence: Double
}
