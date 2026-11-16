import Foundation
import Synchronization
import Testing
@testable import ClassLens

/// Replies with a scripted JSON per call and records the prompts.
private final class ScriptedLLM: LLMClient {
    let replies: Mutex<[String]>
    let prompts = Mutex<[String]>([])

    init(_ replies: [String]) {
        self.replies = Mutex(replies)
    }

    func complete(_ request: ChatRequest) async throws -> String {
        prompts.withLock { $0.append(request.messages.last?.content ?? "") }
        #expect(request.jsonOutput)
        return replies.withLock { $0.isEmpty ? #"{"questions": []}"# : $0.removeFirst() }
    }
}

struct QuestionDetectorTests {
    private var fast: QuestionDetector.Configuration {
        var configuration = QuestionDetector.Configuration()
        configuration.waitAfterLast = .milliseconds(150)
        return configuration
    }

    private func segment(_ text: String, at start: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 3, text: text, isFinal: true)
    }

    private func run(_ detector: QuestionDetector, _ segments: [TranscriptSegment], pause: Duration = .zero) async -> [QuestionDetector.Found] {
        let collector = Task {
            var found: [QuestionDetector.Found] = []
            for await item in detector.found { found.append(item) }
            return found
        }
        for segment in segments {
            await detector.observe(segment)
            if pause > .zero { try? await Task.sleep(for: pause) }
        }
        await detector.finish()
        return await collector.value
    }

    @Test func checksAfterTwoFollowingSegmentsAndKeepsDirectedOnly() async {
        let llm = ScriptedLLM([#"{"questions":[{"line":1,"kind":"directed","signal":"student-answer","english":"What exactly are we testing?","chinese":"我们到底在检验什么？"},{"line":0,"kind":"rhetorical"}]}"#])
        let detector = QuestionDetector(client: llm, model: "deepseek-flash", configuration: fast)
        let found = await run(detector, [
            segment("Today we test a single population.", at: 0),
            segment("So how can we formalize this? What exactly are we testing?", at: 3),
            segment("Let's go.", at: 6),
            segment("Anyone?", at: 9),
        ])
        #expect(found.count == 1)
        #expect(found.first?.chinese == "我们到底在检验什么？")
        #expect(found.first?.at == 3)
        let prompt = llm.prompts.withLock { $0.first } ?? ""
        // Segments are 3 s long and back to back: the pause shown is the 0.4 s of padding.
        #expect(prompt.contains("*[1] 0:03 (pause 0.4s) So how can we formalize this?"))
        #expect(prompt.contains(" [2] 0:06 (pause 0.4s) Let's go."))
        #expect(prompt.contains(" [3] 0:09 (pause ?) Anyone?"))
        #expect(await detector.modelCalls == 1)
    }

    @Test func noModelCallWithoutCandidates() async {
        let llm = ScriptedLLM([])
        let detector = QuestionDetector(client: llm, model: "m", configuration: fast)
        _ = await run(detector, [segment("The mean is unbiased.", at: 0), segment("Right?", at: 3), segment("Variance matters.", at: 6)])
        #expect(await detector.modelCalls == 0)
    }

    @Test func checksAfterQuietTimeout() async {
        let llm = ScriptedLLM([#"{"questions":[{"line":0,"kind":"directed","signal":"student-answer","english":"What is the population here?","chinese":"这里的总体是什么？"}]}"#])
        let detector = QuestionDetector(client: llm, model: "m", configuration: fast)
        let collector = Task { () -> [QuestionDetector.Found] in
            var found: [QuestionDetector.Found] = []
            for await item in detector.found { found.append(item) }
            return found
        }
        await detector.observe(segment("What is the population that this sample represents?", at: 0))
        try? await Task.sleep(for: .milliseconds(400))
        // Found by the timer, before finish() is called, and the model is told nobody spoke.
        #expect(await detector.modelCalls == 1)
        #expect(llm.prompts.withLock { $0.first?.contains("(no speech for at least 0 s after the last line)") } == true)
        await detector.finish()
        #expect(await collector.value.count == 1)
    }

    @Test func keepsWaitingWhileTheTeacherIsStillTalking() async {
        let llm = ScriptedLLM([])
        var configuration = fast
        configuration.waitAfterLast = .milliseconds(200)
        configuration.maximumBatchAge = .seconds(5)
        let detector = QuestionDetector(client: llm, model: "m", configuration: configuration)
        await detector.observe(segment("Or does it have a smaller variance?", at: 0))
        // A long next sentence: only partials for 600 ms, three times the quiet wait.
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            await detector.noteSpeech()
        }
        #expect(await detector.modelCalls == 0)
        await detector.observe(segment("So the formalization of this competing hypothesis is done with a formula.", at: 3))
        await detector.observe(segment("In which I'm using theta.", at: 15))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await detector.modelCalls == 1)
        // Checked because two segments followed, so the prompt must not claim silence.
        #expect(llm.prompts.withLock { $0.first?.contains("no speech") } == false)
        await detector.finish()
    }

    @Test func ignoresUnmarkedLinesAndDuplicates() async {
        let llm = ScriptedLLM([
            #"{"questions":[{"line":0,"kind":"directed","signal":"student-answer","english":"What is the null hypothesis?"}]}"#,
            // Points at line 4, "Think.", which was not marked as a question.
            #"{"questions":[{"line":4,"kind":"directed","signal":"student-answer","english":"Why is the sample biased?"}]}"#,
            // The first question reworded.
            #"{"questions":[{"line":6,"kind":"directed","signal":"student-answer","english":"What is the null hypothesis here?"}]}"#,
        ])
        let detector = QuestionDetector(client: llm, model: "m", configuration: fast)
        let found = await run(detector, [
            segment("What is the null hypothesis?", at: 0),
            segment("Think.", at: 3), segment("Okay.", at: 6),
            segment("Why would the sample be biased?", at: 9),
            segment("Think.", at: 12), segment("Okay.", at: 15),
            segment("So, what is the null hypothesis here?", at: 18),
            segment("Think.", at: 21), segment("Okay.", at: 24),
        ])
        #expect(found.map(\.english) == ["What is the null hypothesis?"])
        #expect(await detector.modelCalls == 3)
    }

    @Test func parsesJSONWrappedInText() {
        let entries = QuestionDetector.parse("Sure:\n```json\n{\"questions\":[{\"line\":4,\"kind\":\"directed\",\"signal\":\"teacher-repeats\",\"english\":\"Why?\"}]}\n```")
        #expect(entries == [.init(line: 4, kind: "directed", signal: "teacher-repeats", evidence: nil, english: "Why?", chinese: nil)])
        #expect(QuestionDetector.parse("no json").isEmpty)
    }

    @Test func dropsDirectedWithoutAnAnswerSignal() async {
        let llm = ScriptedLLM([#"{"questions":[{"line":0,"kind":"directed","signal":"silence-only","english":"Where did this come from?"},{"line":0,"kind":"directed","english":"Where did this come from?"}]}"#])
        let detector = QuestionDetector(client: llm, model: "m", configuration: fast)
        let found = await run(detector, [segment("So where did this come from?", at: 0), segment("Okay.", at: 3), segment("So.", at: 6)])
        #expect(found.isEmpty)
        #expect(await detector.modelCalls == 1)
    }
}

struct StreamParsingTests {
    @Test func readsServerSentEvents() {
        #expect(OpenAICompatibleClient.parseStreamLine(#"data: {"choices":[{"delta":{"content":"答"}}]}"#) == .text("答"))
        #expect(OpenAICompatibleClient.parseStreamLine("data: [DONE]") == .done)
        #expect(OpenAICompatibleClient.parseStreamLine(": keep-alive") == .skip)
        #expect(OpenAICompatibleClient.parseStreamLine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == .skip)
    }
}
