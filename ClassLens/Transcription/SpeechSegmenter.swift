import Foundation

/// A stretch of speech between pauses, the unit the recognizer transcribes.
struct Utterance: Sendable, Equatable, Identifiable {
    let id: UUID
    /// Index of the first sample since the start of the session.
    let startSample: Int
    let samples: [Float]
    /// Where the speech stopped, before the trailing padding; equals `endSample` for a cut.
    let speechEndSample: Int
    /// The sample whose arrival completed this utterance, i.e. when the segmenter decided it was over.
    let decidedAtSample: Int
    /// True when a pause ended it, false when it was cut at the length limit or flushed.
    let endedByPause: Bool

    var endSample: Int { startSample + samples.count }
    var duration: TimeInterval { Double(samples.count) / LectureAudio.sampleRate }
    var startTime: TimeInterval { Double(startSample) / LectureAudio.sampleRate }
    var endTime: TimeInterval { Double(endSample) / LectureAudio.sampleRate }
}

/// Splits a continuous 16 kHz stream into utterances at pauses, using frame energy against an adaptive noise floor.
/// Long stretches without a pause are cut at the quietest moment near the length limit.
struct SpeechSegmenter {
    struct Configuration: Sendable {
        /// 30 ms frames.
        var frameLength = 480
        /// Consecutive loud frames needed to start speech (90 ms), so clicks don't start an utterance.
        var framesToStart = 3
        /// Pause that ends an utterance.
        var pauseToEnd: TimeInterval = 0.6
        /// Silence kept on each side so the first and last syllables aren't clipped.
        var padding: TimeInterval = 0.2
        /// Loud audio an utterance needs, padding not counted; shorter bursts are noise or a cough.
        var minimumSpeech: TimeInterval = 0.25
        var maximumDuration: TimeInterval = 15
        /// How far back from the limit to look for the quietest frame to cut at.
        var cutSearchWindow: TimeInterval = 3
        /// Speech is this many dB above the noise floor…
        var thresholdAboveFloor: Float = 10
        /// …and never quieter than this, so a silent room doesn't make breathing count as speech.
        var minimumThreshold: Float = -50
    }

    let configuration: Configuration
    private(set) var noiseFloor: Float = -60
    /// Samples not yet a whole frame.
    private var remainder: [Float] = []
    /// Index of the next sample to arrive.
    private var position = 0
    /// Recent quiet frames kept as lead-in for the next utterance.
    private var leadIn: [Float] = []
    private var loudRun: [Float] = []
    private var active: (id: UUID, start: Int, samples: [Float], levels: [Float], quietFrames: Int, loudFrames: Int)?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The utterance still being spoken, for partial results.
    var current: Utterance? {
        active.map {
            let end = $0.start + $0.samples.count
            return Utterance(id: $0.id, startSample: $0.start, samples: $0.samples, speechEndSample: end, decidedAtSample: end, endedByPause: false)
        }
    }

    /// Feeds samples and returns the utterances they completed.
    mutating func append(_ samples: [Float]) -> [Utterance] {
        remainder.append(contentsOf: samples)
        let length = configuration.frameLength
        var finished: [Utterance] = []
        var offset = 0
        while remainder.count - offset >= length {
            let frame = Array(remainder[offset..<offset + length])
            offset += length
            if let utterance = process(frame) { finished.append(contentsOf: utterance) }
        }
        remainder.removeFirst(offset)
        return finished
    }

    /// Ends the stream: returns whatever is still being spoken.
    mutating func flush() -> Utterance? {
        defer { active = nil }
        guard let active else { return nil }
        guard isSpeech(loudFrames: active.loudFrames) else { return nil }
        let end = active.start + active.samples.count
        return Utterance(id: active.id, startSample: active.start, samples: active.samples, speechEndSample: end, decidedAtSample: position, endedByPause: false)
    }

    private func isSpeech(loudFrames: Int) -> Bool {
        Double(loudFrames * configuration.frameLength) / LectureAudio.sampleRate >= configuration.minimumSpeech
    }

    private var threshold: Float { max(noiseFloor + configuration.thresholdAboveFloor, configuration.minimumThreshold) }
    /// Padding rounded down to whole frames, so frame levels stay aligned with samples.
    private var paddingSamples: Int { Int(configuration.padding * LectureAudio.sampleRate) / configuration.frameLength * configuration.frameLength }

    private mutating func process(_ frame: [Float]) -> [Utterance]? {
        let level = 20 * log10(max(LectureAudio.rms(frame), 1e-7))
        let loud = level > threshold
        defer { position += frame.count }

        guard var current = active else {
            if loud {
                loudRun.append(contentsOf: frame)
                if loudRun.count >= configuration.framesToStart * configuration.frameLength {
                    let samples = leadIn + loudRun
                    let levels = Array(repeating: level, count: samples.count / configuration.frameLength)
                    active = (UUID(), position + frame.count - samples.count, samples, levels, 0, configuration.framesToStart)
                    leadIn = []
                    loudRun = []
                }
            } else {
                // A quiet frame: learn the room's noise, fast downward and slowly upward.
                noiseFloor = level < noiseFloor ? noiseFloor * 0.8 + level * 0.2 : noiseFloor * 0.995 + level * 0.005
                leadIn.append(contentsOf: loudRun)
                leadIn.append(contentsOf: frame)
                loudRun = []
                if leadIn.count > paddingSamples { leadIn.removeFirst(leadIn.count - paddingSamples) }
            }
            return nil
        }

        current.samples.append(contentsOf: frame)
        current.levels.append(level)
        current.quietFrames = loud ? 0 : current.quietFrames + 1
        if loud { current.loudFrames += 1 }
        active = current

        let pauseFrames = Int(configuration.pauseToEnd * LectureAudio.sampleRate) / configuration.frameLength
        if current.quietFrames >= pauseFrames {
            // Keep `padding` of the pause, hand the rest to the lead-in of the next utterance.
            let quietSamples = current.quietFrames * configuration.frameLength
            let keep = current.samples.count - quietSamples + min(paddingSamples, quietSamples)
            leadIn = Array(current.samples[keep...].suffix(paddingSamples))
            active = nil
            guard isSpeech(loudFrames: current.loudFrames) else { return nil }
            let speechEnd = current.start + current.samples.count - quietSamples
            return [Utterance(id: current.id, startSample: current.start, samples: Array(current.samples[..<keep]), speechEndSample: speechEnd, decidedAtSample: position + frame.count, endedByPause: true)]
        }

        let limit = Int(configuration.maximumDuration * LectureAudio.sampleRate)
        if current.samples.count >= limit {
            // Cut at the quietest frame in the search window; the rest starts the next utterance.
            let windowFrames = Int(configuration.cutSearchWindow * LectureAudio.sampleRate) / configuration.frameLength
            let firstCandidate = max(1, current.levels.count - windowFrames)
            let cutFrame = (firstCandidate..<current.levels.count).min { current.levels[$0] < current.levels[$1] } ?? current.levels.count - 1
            let cut = cutFrame * configuration.frameLength
            let head = Utterance(id: current.id, startSample: current.start, samples: Array(current.samples[..<cut]), speechEndSample: current.start + cut, decidedAtSample: position + frame.count, endedByPause: false)
            let tail = Array(current.levels[cutFrame...])
            // The cut often lands in a pause, so the tail can be shorter than the quiet run so far; count its
            // own trailing quiet frames rather than carrying the old count over (that made the pause check
            // index before the start of the tail and crash).
            let trailingQuiet = tail.reversed().prefix { $0 <= threshold }.count
            active = (UUID(), current.start + cut, Array(current.samples[cut...]), tail, trailingQuiet, tail.filter { $0 > threshold }.count)
            return [head]
        }
        return nil
    }
}
