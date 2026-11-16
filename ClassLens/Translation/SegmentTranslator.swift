import Foundation

/// Translates final transcript segments into Chinese, each with the previous few segments as context.
///
/// Requests run up to three at a time so one slow reply doesn't hold up the next subtitles. A segment's
/// English joins the context as soon as it arrives; its Chinese joins once translated.
actor SegmentTranslator {
    struct Outcome: Sendable {
        var id: UUID
        var translation: String?
        var error: String?
        /// Seconds from asking to having the translation (or giving up).
        var latency: Double
    }

    private let client: any LLMClient
    private let model: String
    private let maxConcurrent: Int
    private let contextCount = 3
    private var glossary: [String] = []
    private var history: [(id: UUID, english: String, chinese: String?)] = []
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let clock = ContinuousClock()

    init(client: any LLMClient, model: String, maxConcurrent: Int = 3) {
        self.client = client
        self.model = model
        self.maxConcurrent = maxConcurrent
    }

    func setGlossary(_ terms: [String]) {
        glossary = terms
    }

    func translate(_ segment: TranscriptSegment) async -> Outcome {
        let started = clock.now
        let previous = history.suffix(contextCount).map { ($0.english, $0.chinese) }
        history.append((segment.id, segment.text, nil))
        if history.count > 20 { history.removeFirst(history.count - 20) }

        await acquire()
        defer { release() }
        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: TranslationPrompts.system),
                ChatMessage(role: .user, content: TranslationPrompts.user(current: segment.text, previous: previous, glossary: glossary)),
            ],
            temperature: 0.3,
            maxTokens: 400
        )
        do {
            let chinese = Self.clean(try await completeWithRetry(request))
            if let index = history.lastIndex(where: { $0.id == segment.id }) { history[index].chinese = chinese }
            return Outcome(id: segment.id, translation: chinese, latency: seconds(since: started))
        } catch {
            return Outcome(id: segment.id, error: error.localizedDescription, latency: seconds(since: started))
        }
    }

    /// One retry after a second for failures that usually pass: rate limits, server errors, timeouts.
    private func completeWithRetry(_ request: ChatRequest) async throws -> String {
        do {
            return try await client.complete(request)
        } catch let failure as LLMFailure {
            switch failure {
            case .rateLimited, .server, .emptyReply: break
            case .missingKey, .invalidKey, .insufficientBalance, .refused: throw failure
            }
        } catch is URLError {
        }
        try await Task.sleep(for: .seconds(1))
        return try await client.complete(request)
    }

    /// Models sometimes echo a label or wrap the answer in quotes despite the prompt.
    static func clean(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ZH:", "ZH：", "中文：", "中文:", "译文：", "译文:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let quotes: [(Character, Character)] = [("“", "”"), ("\"", "\""), ("「", "」")]
        for (open, close) in quotes where text.count > 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            // Hand the slot straight to the next waiter.
            waiting.removeFirst().resume()
        }
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
