import Foundation
import Testing
@testable import ClassLens

/// Synthetic audio: quiet noise around -66 dB, "speech" as a tone around -23 dB.
enum SyntheticAudio {
    static func silence(_ seconds: Double) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * LectureAudio.sampleRate)).map { _ in Float.random(in: -0.0008...0.0008, using: &generator) }
    }

    static func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * LectureAudio.sampleRate)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(LectureAudio.sampleRate)) }
    }

    /// Feeds in 100 ms chunks, the size the microphone and replay deliver.
    static func chunks(_ samples: [Float]) -> [[Float]] {
        stride(from: 0, to: samples.count, by: 1600).map { Array(samples[$0..<min($0 + 1600, samples.count)]) }
    }
}

struct SpeechSegmenterTests {
    private func run(_ audio: [Float], configuration: SpeechSegmenter.Configuration = .init()) -> [Utterance] {
        var segmenter = SpeechSegmenter(configuration: configuration)
        var utterances = SyntheticAudio.chunks(audio).flatMap { segmenter.append($0) }
        if let last = segmenter.flush() { utterances.append(last) }
        return utterances
    }

    @Test func splitsAtPauses() {
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(2) + SyntheticAudio.silence(1) + SyntheticAudio.tone(3) + SyntheticAudio.silence(1)
        let utterances = run(audio)
        #expect(utterances.count == 2)
        // Each keeps about 0.2 s of padding on both sides of the tone.
        #expect(abs(utterances[0].startTime - 0.8) < 0.15)
        #expect(abs(utterances[0].endTime - 3.2) < 0.15)
        #expect(abs(utterances[1].startTime - 3.8) < 0.15)
        #expect(abs(utterances[1].endTime - 7.2) < 0.15)
    }

    @Test func shortPausesStayInOneUtterance() {
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(1.5) + SyntheticAudio.silence(0.3) + SyntheticAudio.tone(1.5) + SyntheticAudio.silence(1)
        #expect(run(audio).count == 1)
    }

    @Test func dropsClicksAndShortNoise() {
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(0.05) + SyntheticAudio.silence(1) + SyntheticAudio.tone(0.15) + SyntheticAudio.silence(1)
        #expect(run(audio).isEmpty)
    }

    @Test func keepsAShortWord() {
        // "Yes." or "Okay." is about 0.4 s.
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(0.4) + SyntheticAudio.silence(1)
        #expect(run(audio).count == 1)
    }

    @Test func cutsLongSpeechWithoutLosingAudio() {
        let tone = SyntheticAudio.tone(40)
        let audio = SyntheticAudio.silence(1) + tone + SyntheticAudio.silence(1)
        let utterances = run(audio)
        #expect(utterances.count >= 3)
        #expect(utterances.allSatisfy { $0.duration <= 15.05 })
        // Consecutive pieces touch: nothing between cuts is dropped.
        for (previous, next) in zip(utterances, utterances.dropFirst()) {
            #expect(previous.endSample == next.startSample)
        }
        #expect(Set(utterances.map(\.id)).count == utterances.count)
    }

    /// Regression: a cut that lands in a pause used to carry the whole quiet count into a shorter tail,
    /// and the next pause check indexed before the tail's start and crashed.
    @Test func cutInsideAPauseDoesNotCrash() {
        var configuration = SpeechSegmenter.Configuration()
        configuration.maximumDuration = 2
        configuration.cutSearchWindow = 3
        let audio = SyntheticAudio.silence(1) + SyntheticAudio.tone(1.9) + SyntheticAudio.silence(2) + SyntheticAudio.tone(1) + SyntheticAudio.silence(1)
        let utterances = run(audio, configuration: configuration)
        #expect(!utterances.isEmpty)
        #expect(utterances.allSatisfy { $0.duration <= 2.05 && $0.speechEndSample <= $0.endSample })
    }

    @Test func flushReturnsSpeechInProgress() {
        var segmenter = SpeechSegmenter()
        _ = SyntheticAudio.chunks(SyntheticAudio.silence(1) + SyntheticAudio.tone(2)).flatMap { segmenter.append($0) }
        #expect(segmenter.current != nil)
        let last = segmenter.flush()
        #expect(last != nil)
        #expect(segmenter.current == nil)
    }
}
