import Foundation

/// Turns a live 16 kHz stream into partial and final transcript segments.
///
/// Qwen3-ASR is not a streaming model, so the stream is cut into utterances at pauses. A finished
/// utterance is transcribed once for its final text; while one is being spoken, it is re-transcribed
/// about every second for a partial. Recognition runs one job at a time: finals go first and in order,
/// and only the newest partial is kept, so a slow pass never builds a backlog.
actor LiveTranscriber {
    struct Configuration: Sendable {
        var segmenter = SpeechSegmenter.Configuration()
        /// New audio needed before the partial is refreshed.
        var partialInterval: TimeInterval = 1.0
        /// Utterances shorter than this get no partial; the model guesses on very short audio.
        var partialMinimumDuration: TimeInterval = 1.0
        /// Shorter utterances are transcribed without the vocabulary: a few words gain little from it,
        /// and short near-silent audio is where the recognizer repeats the context instead.
        var vocabularyMinimumDuration: TimeInterval = 2.0
    }

    private struct Job {
        let utterance: Utterance
        let isFinal: Bool
    }

    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private let engine: any TranscriptionEngine
    private let configuration: Configuration
    private let clock = ContinuousClock()
    private var segmenter: SpeechSegmenter
    private var vocabulary: [String] = []
    private var finals: [Job] = []
    private var newestPartial: Job?
    private var working = false
    private var drained: [CheckedContinuation<Void, Never>] = []
    private var finished: Set<UUID> = []
    private var lastPartialEnd: [UUID: Int] = [:]
    /// When each chunk's last sample arrived, to measure latency against the audio.
    private var arrivals: [(endSample: Int, at: ContinuousClock.Instant)] = []
    private var receivedSamples = 0
    private(set) var metrics = TranscriptionMetrics()
    /// `CLASSLENS_TRACE=1` prints one line per recognition job, for latency debugging.
    private let trace = ProcessInfo.processInfo.environment["CLASSLENS_TRACE"] == "1"

    init(engine: any TranscriptionEngine, configuration: Configuration = Configuration()) {
        self.engine = engine
        self.configuration = configuration
        self.segmenter = SpeechSegmenter(configuration: configuration.segmenter)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    var receivedSeconds: TimeInterval { Double(receivedSamples) / LectureAudio.sampleRate }

    /// Course terms passed to the recognizer with utterances long enough to benefit.
    func setVocabulary(_ terms: [String]) {
        vocabulary = terms
    }

    func append(_ samples: [Float]) {
        receivedSamples += samples.count
        let now = clock.now
        arrivals.append((receivedSamples, now))
        // Latency is measured within a few seconds; older arrivals are never looked up.
        if arrivals.count > 600 { arrivals.removeFirst(arrivals.count - 600) }

        for utterance in segmenter.append(samples) {
            finals.append(Job(utterance: utterance, isFinal: true))
        }
        if let current = segmenter.current, current.duration >= configuration.partialMinimumDuration {
            let since = current.endSample - lastPartialEnd[current.id, default: current.startSample]
            if Double(since) >= configuration.partialInterval * LectureAudio.sampleRate {
                newestPartial = Job(utterance: current, isFinal: false)
                lastPartialEnd[current.id] = current.endSample
            }
        }
        startWorking()
    }

    /// Transcribes what is still being spoken, waits for all pending work, then ends `events`.
    func finish() async {
        if let last = segmenter.flush() {
            finals.append(Job(utterance: last, isFinal: true))
        }
        newestPartial = nil
        startWorking()
        if working {
            await withCheckedContinuation { drained.append($0) }
        }
        continuation.finish()
    }

    private func startWorking() {
        guard !working, !finals.isEmpty || newestPartial != nil else { return }
        working = true
        Task { await work() }
    }

    private func work() async {
        while let job = nextJob() {
            let started = clock.now
            do {
                let raw = try await transcribe(job.utterance)
                let took = seconds(clock.now - started)
                metrics.computeSeconds += took
                if trace {
                    let behind = Double(receivedSamples - job.utterance.endSample) / LectureAudio.sampleRate
                    print(String(format: "trace %@ audio %.1fs took %.2fs, stream ahead by %.1fs, finals waiting %d", job.isFinal ? "final  " : "partial", job.utterance.duration, took, behind, finals.count))
                }
                metrics.recognizedAudioSeconds += job.utterance.duration
                let cleaned = RepetitionGuard.collapse(raw)
                if cleaned.collapsed { metrics.repetitionsCollapsed += 1 }
                emit(job, text: cleaned.text)
            } catch {
                metrics.errors += 1
                if job.isFinal {
                    finished.insert(job.utterance.id)
                    continuation.yield(.final(segment(job, text: "")))
                }
                continuation.yield(.failed(error.localizedDescription))
            }
        }
        working = false
        drained.forEach { $0.resume() }
        drained = []
    }

    /// Uses the vocabulary when it can help, and transcribes again without it if the result just repeats it.
    private func transcribe(_ utterance: Utterance) async throws -> String {
        guard !vocabulary.isEmpty, utterance.duration >= configuration.vocabularyMinimumDuration else {
            return try await engine.transcribe(utterance.samples, context: "")
        }
        let terms = vocabulary
        let text = try await engine.transcribe(utterance.samples, context: ContextEcho.context(for: terms))
        guard ContextEcho.isEcho(text, terms: terms) else { return text }
        metrics.contextEchoes += 1
        return try await engine.transcribe(utterance.samples, context: "")
    }

    private func nextJob() -> Job? {
        if !finals.isEmpty { return finals.removeFirst() }
        defer { newestPartial = nil }
        guard let partial = newestPartial, !finished.contains(partial.utterance.id) else { return nil }
        return partial
    }

    private func emit(_ job: Job, text: String) {
        let utterance = job.utterance
        if job.isFinal {
            finished.insert(utterance.id)
            lastPartialEnd[utterance.id] = nil
            if utterance.endedByPause {
                if let stopped = arrival(of: utterance.speechEndSample) { metrics.finalLatencies.append(seconds(clock.now - stopped)) }
            } else if let decided = arrival(of: utterance.decidedAtSample) {
                metrics.cutFinalLatencies.append(seconds(clock.now - decided))
            }
            continuation.yield(.final(segment(job, text: text)))
        } else {
            guard !finished.contains(utterance.id), !text.isEmpty else { return }
            if let newest = arrival(of: utterance.endSample) { metrics.partialLatencies.append(seconds(clock.now - newest)) }
            continuation.yield(.partial(segment(job, text: text)))
        }
    }

    private func segment(_ job: Job, text: String) -> TranscriptSegment {
        TranscriptSegment(id: job.utterance.id, start: job.utterance.startTime, end: job.utterance.endTime, text: text, isFinal: job.isFinal)
    }

    private func arrival(of sample: Int) -> ContinuousClock.Instant? {
        arrivals.first { $0.endSample >= sample }?.at
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
