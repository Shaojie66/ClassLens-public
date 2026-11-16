import Foundation
import Synchronization
import Testing
@testable import ClassLens

/// Answers with the utterance length, after a delay that stands in for model time.
private final class FakeEngine: TranscriptionEngine {
    let name = "fake"
    let delay: Duration
    let calls = Mutex<[Int]>([])

    init(delay: Duration = .milliseconds(5)) {
        self.delay = delay
    }

    func transcribe(_ samples: [Float], context: String) async throws -> String {
        calls.withLock { $0.append(samples.count) }
        try await Task.sleep(for: delay)
        return "utterance of \(samples.count) samples"
    }
}

/// Repeats the context back when given one, like Qwen3-ASR does on near-silent audio.
private final class EchoingEngine: TranscriptionEngine {
    let name = "echo"
    let contexts = Mutex<[String]>([])

    func transcribe(_ samples: [Float], context: String) async throws -> String {
        contexts.withLock { $0.append(context) }
        return context.isEmpty ? "real words" : context
    }
}

struct LiveTranscriberTests {
    @Test func retriesWithoutVocabularyWhenTheEngineEchoesIt() async {
        let engine = EchoingEngine()
        var configuration = LiveTranscriber.Configuration()
        configuration.partialMinimumDuration = 100 // finals only, to keep the call list short
        let transcriber = LiveTranscriber(engine: engine, configuration: configuration)
        await transcriber.setVocabulary(["null hypothesis", "rejection region", "type I error", "t distribution", "H0"])
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(3) + SyntheticAudio.silence(1) + SyntheticAudio.tone(1) + SyntheticAudio.silence(1)
        let finals = await collect(transcriber, feeding: audio).compactMap { event -> String? in
            if case .final(let segment) = event { segment.text } else { nil }
        }
        #expect(finals == ["real words", "real words"])
        // The 3 s utterance tried the vocabulary first, then again without it; the 1 s one never used it.
        #expect(engine.contexts.withLock { $0.map(\.isEmpty) } == [false, true, true])
        #expect(await transcriber.metrics.contextEchoes == 1)
    }

    private func collect(_ transcriber: LiveTranscriber, feeding audio: [Float], pace: Duration? = nil) async -> [TranscriptionEvent] {
        let collector = Task {
            var events: [TranscriptionEvent] = []
            for await event in transcriber.events { events.append(event) }
            return events
        }
        for chunk in SyntheticAudio.chunks(audio) {
            await transcriber.append(chunk)
            if let pace { try? await Task.sleep(for: pace) }
        }
        await transcriber.finish()
        return await collector.value
    }

    @Test func emitsOneFinalPerUtteranceInOrder() async {
        let transcriber = LiveTranscriber(engine: FakeEngine())
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(2) + SyntheticAudio.silence(1) + SyntheticAudio.tone(2) + SyntheticAudio.silence(1)
        let finals = await collect(transcriber, feeding: audio).compactMap { event -> TranscriptSegment? in
            if case .final(let segment) = event { segment } else { nil }
        }
        #expect(finals.count == 2)
        #expect(finals[0].start < finals[1].start)
        #expect(finals.allSatisfy { $0.isFinal && !$0.text.isEmpty })
        let metrics = await transcriber.metrics
        #expect(metrics.finalLatencies.count == 2)
    }

    @Test func partialsShareTheFinalsIdAndNeverFollowIt() async {
        let transcriber = LiveTranscriber(engine: FakeEngine())
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(4) + SyntheticAudio.silence(1)
        // Real-time-ish pacing so partials get a chance to run.
        let events = await collect(transcriber, feeding: audio, pace: .milliseconds(20))
        let partials = events.compactMap { event -> TranscriptSegment? in if case .partial(let s) = event { s } else { nil } }
        let finals = events.compactMap { event -> TranscriptSegment? in if case .final(let s) = event { s } else { nil } }
        #expect(!partials.isEmpty)
        #expect(finals.count == 1)
        #expect(partials.allSatisfy { $0.id == finals[0].id && !$0.isFinal })
        if case .final = events.last {} else { Issue.record("the final must be the last event") }
    }

    @Test func slowEngineDropsStalePartialsInsteadOfQueueing() async {
        let engine = FakeEngine(delay: .milliseconds(300))
        let transcriber = LiveTranscriber(engine: engine)
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(8) + SyntheticAudio.silence(1)
        let clock = ContinuousClock()
        let started = clock.now
        _ = await collect(transcriber, feeding: audio, pace: .milliseconds(25))
        let elapsed = clock.now - started
        // No backlog: the engine was never asked for more than it could do back to back, plus the final.
        #expect(engine.calls.withLock { $0.count } <= Int(elapsed / .milliseconds(300)) + 1)
        // And it did refresh partials while speech went on, rather than skipping them all.
        #expect(engine.calls.withLock { $0.count } >= 3)
    }

    @Test func finishTranscribesSpeechStillInProgress() async {
        let transcriber = LiveTranscriber(engine: FakeEngine())
        let events = await collect(transcriber, feeding: SyntheticAudio.silence(1) + SyntheticAudio.tone(2))
        #expect(events.contains { if case .final = $0 { true } else { false } })
    }
}
