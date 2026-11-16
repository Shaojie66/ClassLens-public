import Foundation

/// Asks the fast model which slide the lecturer is on, by meaning rather than word overlap, so slides
/// that are mostly a figure and recurring examples can be told apart.
struct SlideLocator: Sendable {
    struct Answer: Equatable, Sendable {
        /// 0-based slide.
        var slide: Int
        var confidence: Double
    }

    let client: any LLMClient
    let model: String
    let slideCount: Int
    private let system: String

    init(client: any LLMClient, model: String, slideTexts: [String]) {
        self.client = client
        self.model = model
        self.slideCount = slideTexts.count
        self.system = SlidePrompts.system(outline: SlidePrompts.outline(slideTexts))
    }

    /// `previous` is the 0-based slide from the last call, if any.
    func locate(recent: String, previous: Int?) async throws -> Answer? {
        let reply = try await client.complete(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: system),
                ChatMessage(role: .user, content: SlidePrompts.user(recent: recent, previous: previous.map { $0 + 1 })),
            ],
            temperature: 0,
            maxTokens: 60,
            jsonOutput: true
        ))
        return Self.parse(reply, slideCount: slideCount)
    }

    static func parse(_ reply: String, slideCount: Int) -> Answer? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        struct Reply: Decodable { var slide: Int?; var confidence: Double? }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: Data(reply[start...end].utf8)),
              let slide = decoded.slide, (1...slideCount).contains(slide) else { return nil }
        return Answer(slide: slide - 1, confidence: min(1, max(0, decoded.confidence ?? 0.5)))
    }
}
