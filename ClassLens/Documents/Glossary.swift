import Foundation

struct GlossaryTerm: Codable, Sendable, Equatable {
    var english: String
    var chinese: String
}

/// Course terms from the open slides. One list serves three jobs: biasing recognition, keeping
/// translations consistent, and grounding answers.
struct Glossary: Codable, Sendable, Equatable {
    var documentFingerprint: String
    var terms: [GlossaryTerm]

    /// English terms for the recognizer's context, longest first so multi-word terms aren't crowded out.
    /// Single Latin letters (s, n) are left out: they only distract the recognizer; symbols like θ stay.
    var recognitionTerms: [String] {
        let useful = terms.map(\.english).filter { $0.count > 1 || !$0.allSatisfy(\.isASCII) }
        return Array(useful.sorted { $0.count > $1.count }.prefix(60))
    }

    /// "english → 中文" lines for the translation and answer prompts.
    var translationLines: [String] {
        terms.map { $0.chinese.isEmpty ? $0.english : "\($0.english) → \($0.chinese)" }
    }
}

/// Glossaries saved under `~/Library/Application Support/ClassLens/glossaries/<fingerprint>.v<version>.json`.
enum GlossaryCache {
    /// Bump when extraction changes (prompt, text cleanup) so stale glossaries are rebuilt.
    /// 2: page text gets ligature repair before extraction.
    static let version = 2

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "ClassLens/glossaries", directoryHint: .isDirectory)
    }

    static func file(_ fingerprint: String) -> URL {
        directory.appending(path: "\(fingerprint).v\(version).json")
    }

    static func load(_ fingerprint: String) -> Glossary? {
        guard let data = try? Data(contentsOf: file(fingerprint)) else { return nil }
        return try? JSONDecoder().decode(Glossary.self, from: data)
    }

    static func save(_ glossary: Glossary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(glossary).write(to: file(glossary.documentFingerprint), options: .atomic)
    }
}
