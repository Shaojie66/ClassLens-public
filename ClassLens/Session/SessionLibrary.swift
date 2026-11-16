import Foundation

/// A past lecture as listed in the history.
struct SessionSummary: Identifiable, Equatable, Sendable {
    var id: UUID { meta.id }
    var directory: URL
    var meta: SessionMeta
    /// Recorded seconds; from the meta, or the last caption for sessions recorded before M6.
    var duration: TimeInterval
    var questionCount: Int

    var title: String {
        if let title = meta.title, !title.isEmpty { return title }
        let date = meta.createdAt.formatted(.dateTime.month().day().hour().minute())
        if let name = meta.document?.name { return "\(name) · \(date)" }
        return meta.isReplay ? "回放 · \(date)" : "课堂录音 · \(date)"
    }

    var audioURL: URL { directory.appending(path: "audio.m4a") }
}

/// Everything saved for one lecture, for review.
struct LoadedSession: Sendable {
    var summary: SessionSummary
    var segments: [TranscriptSegment]
    var questions: [ClassQuestion]
    var slides: [SlideMark]
}

/// Lists, opens, renames and deletes saved lectures.
enum SessionLibrary {
    /// Newest first; folders without a readable `meta.json` are skipped.
    static func list(root: URL = SessionStore.root) -> [SessionSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { summary(of: $0) }.sorted { $0.meta.createdAt > $1.meta.createdAt }
    }

    static func summary(of directory: URL) -> SessionSummary? {
        guard let meta = try? SessionMeta.load(from: directory) else { return nil }
        let duration = meta.duration
            ?? (try? SessionStore.loadTranscript(directory.appending(path: "transcript.jsonl")).last?.end)
            ?? 0
        return SessionSummary(directory: directory, meta: meta, duration: duration, questionCount: questions(in: directory).count)
    }

    static func load(_ summary: SessionSummary) throws -> LoadedSession {
        let transcriptURL = summary.directory.appending(path: "transcript.jsonl")
        let segments = FileManager.default.fileExists(atPath: transcriptURL.path) ? try SessionStore.loadTranscript(transcriptURL) : []
        return LoadedSession(summary: summary, segments: segments, questions: questions(in: summary.directory), slides: slides(in: summary.directory))
    }

    static func rename(_ summary: SessionSummary, to title: String) throws -> SessionSummary {
        var meta = summary.meta
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.title = trimmed.isEmpty ? nil : trimmed
        try meta.save(to: summary.directory)
        var renamed = summary
        renamed.meta = meta
        return renamed
    }

    /// Rewrites a saved lecture's `qa.json`, e.g. after asking about it while reviewing.
    static func writeQuestions(_ questions: [ClassQuestion], to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(questions).write(to: directory.appending(path: "qa.json"), options: .atomic)
    }

    /// Moves the session folder to the Trash, so a mistaken delete can be undone in Finder.
    static func delete(_ summary: SessionSummary) throws {
        try FileManager.default.trashItem(at: summary.directory, resultingItemURL: nil)
    }

    private static func questions(in directory: URL) -> [ClassQuestion] {
        guard let data = try? Data(contentsOf: directory.appending(path: "qa.json")) else { return [] }
        return (try? JSONDecoder().decode([ClassQuestion].self, from: data)) ?? []
    }

    private static func slides(in directory: URL) -> [SlideMark] {
        guard let text = try? String(contentsOf: directory.appending(path: "slides.jsonl"), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(SlideMark.self, from: Data($0.utf8)) }
    }
}
