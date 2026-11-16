import Foundation
import Synchronization
import Testing
@testable import ClassLens

private final class FakeLLM: LLMClient {
    let requests = Mutex<[ChatRequest]>([])
    let inFlight = Mutex(0)
    let peakInFlight = Mutex(0)
    let failures: Mutex<[Error]>
    let delay: Duration

    init(delay: Duration = .milliseconds(10), failures: [Error] = []) {
        self.delay = delay
        self.failures = Mutex(failures)
    }

    func complete(_ request: ChatRequest) async throws -> String {
        requests.withLock { $0.append(request) }
        let now = inFlight.withLock { $0 += 1; return $0 }
        peakInFlight.withLock { $0 = max($0, now) }
        defer { inFlight.withLock { $0 -= 1 } }
        try await Task.sleep(for: delay)
        if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw failure }
        let current = request.messages.last?.content.components(separatedBy: "CURRENT segment:\n").last ?? ""
        return "“译：\(current)”"
    }
}

struct SegmentTranslatorTests {
    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(start: 0, end: 1, text: text, isFinal: true)
    }

    @Test func translatesWithPreviousSegmentsAsContext() async {
        let llm = FakeLLM()
        let translator = SegmentTranslator(client: llm, model: "deepseek-flash")
        let first = await translator.translate(segment("The null hypothesis"))
        #expect(first.translation == "译：The null hypothesis")
        _ = await translator.translate(segment("is denoted H0."))
        let prompt = llm.requests.withLock { $0.last?.messages.last?.content } ?? ""
        #expect(prompt.contains("EN: The null hypothesis\nZH: 译：The null hypothesis"))
        #expect(prompt.hasSuffix("CURRENT segment:\nis denoted H0."))
        #expect(llm.requests.withLock { $0.allSatisfy { $0.model == "deepseek-flash" && $0.messages.first?.role == .system } })
    }

    @Test func runsAtMostThreeAtOnce() async {
        let llm = FakeLLM(delay: .milliseconds(100))
        let translator = SegmentTranslator(client: llm, model: "m")
        await withTaskGroup { group in
            for index in 0..<8 {
                group.addTask { _ = await translator.translate(segment("sentence \(index)")) }
            }
        }
        #expect(llm.peakInFlight.withLock { $0 } == 3)
        #expect(llm.requests.withLock { $0.count } == 8)
    }

    @Test func retriesOnceOnRateLimit() async {
        let llm = FakeLLM(failures: [OpenAICompatibleClient.Failure.rateLimited])
        let outcome = await SegmentTranslator(client: llm, model: "m").translate(segment("hello"))
        #expect(outcome.translation == "译：hello")
        #expect(llm.requests.withLock { $0.count } == 2)
    }

    @Test func doesNotRetryABadKey() async {
        let llm = FakeLLM(failures: [OpenAICompatibleClient.Failure.invalidKey])
        let outcome = await SegmentTranslator(client: llm, model: "m").translate(segment("hello"))
        #expect(outcome.translation == nil)
        #expect(outcome.error != nil)
        #expect(llm.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [
        ("ZH: 原假设", "原假设"),
        ("“原假设成立。”", "原假设成立。"),
        ("中文：方差更小", "方差更小"),
        ("H0 表示“无差异”", "H0 表示“无差异”"),
    ])
    func cleansEchoedLabelsAndQuotes(reply: String, expected: String) {
        #expect(SegmentTranslator.clean(reply) == expected)
    }
}
