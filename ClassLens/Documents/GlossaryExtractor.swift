import Foundation

/// Extracts a course glossary from slide text with the fast model.
struct GlossaryExtractor: Sendable {
    let client: any LLMClient
    let model: String

    func extract(text: String, fingerprint: String) async throws -> Glossary {
        let reply = try await client.complete(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: GlossaryPrompts.system),
                ChatMessage(role: .user, content: GlossaryPrompts.user(text)),
            ],
            temperature: 0,
            maxTokens: 3000,
            jsonOutput: true
        ))
        return Glossary(documentFingerprint: fingerprint, terms: Self.parse(reply))
    }

    /// Reads `{"terms": [{"en", "zh"}]}`, dropping blanks and case-insensitive duplicates.
    static func parse(_ reply: String) -> [GlossaryTerm] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return [] }
        struct Reply: Decodable {
            struct Term: Decodable { var en: String?; var zh: String? }
            var terms: [Term]
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: Data(reply[start...end].utf8)) else { return [] }
        var seen: Set<String> = []
        var terms: [GlossaryTerm] = []
        for term in decoded.terms {
            let english = (term.en ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, english.count <= 60, seen.insert(english.lowercased()).inserted else { continue }
            terms.append(GlossaryTerm(english: english, chinese: (term.zh ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return Array(terms.prefix(80))
    }
}
