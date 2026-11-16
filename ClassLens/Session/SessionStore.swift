import Foundation

/// Saves one lecture under `~/Library/Application Support/ClassLens/sessions/<id>/`:
/// `meta.json`, `audio.m4a`, `transcript.jsonl`, `qa.json` and `slides.jsonl`.
///
/// `transcript.jsonl` is append-only: a segment is written when its English is final and again when its
/// translation arrives, so nothing is lost if the app quits in between. Readers keep the last line per id.
actor SessionStore {
    nonisolated let directory: URL
    private(set) var meta: SessionMeta
    private let audio: AudioFileWriter
    private let transcript: FileHandle
    private let slides: FileHandle
    private let encoder = JSONEncoder()

    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "ClassLens/sessions", directoryHint: .isDirectory)
    }

    init(source: String, engine: String, document: SessionMeta.Document? = nil, root: URL = SessionStore.root) throws {
        let meta = SessionMeta(id: UUID(), createdAt: .now, source: source, engine: engine, document: document)
        directory = root.appending(path: meta.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try meta.save(to: directory)
        self.meta = meta
        audio = try AudioFileWriter(url: directory.appending(path: "audio.m4a"))
        transcript = try Self.appendHandle(directory.appending(path: "transcript.jsonl"))
        slides = try Self.appendHandle(directory.appending(path: "slides.jsonl"))
    }

    private static func appendHandle(_ url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    /// The slides opened (or changed) during the lecture.
    func setDocument(_ document: SessionMeta.Document?) throws {
        meta.document = document
        try meta.save(to: directory)
    }

    func appendSlide(_ mark: SlideMark) throws {
        var line = try encoder.encode(mark)
        line.append(0x0A)
        try slides.write(contentsOf: line)
    }

    func writeAudio(_ samples: [Float]) throws {
        try audio.write(samples)
    }

    func append(_ segment: TranscriptSegment) throws {
        guard segment.isFinal, !segment.text.isEmpty else { return }
        var line = try encoder.encode(segment)
        line.append(0x0A)
        try transcript.write(contentsOf: line)
    }

    /// Rewrites `qa.json` with the session's questions and answers.
    func writeQuestions(_ questions: [ClassQuestion]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(questions).write(to: directory.appending(path: "qa.json"), options: .atomic)
    }

    /// Reads a transcript, keeping the latest version of each segment in first-seen order.
    static func loadTranscript(_ url: URL) throws -> [TranscriptSegment] {
        let decoder = JSONDecoder()
        var order: [UUID] = []
        var latest: [UUID: TranscriptSegment] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            let segment = try decoder.decode(TranscriptSegment.self, from: Data(line.utf8))
            if latest[segment.id] == nil { order.append(segment.id) }
            latest[segment.id] = segment
        }
        return order.compactMap { latest[$0] }
    }

    /// Records how long the lecture was and closes the files.
    func close(duration: TimeInterval) throws {
        audio.close()
        try transcript.close()
        try slides.close()
        meta.endedAt = .now
        meta.duration = duration
        try meta.save(to: directory)
    }
}
