import Foundation

/// Latency and throughput of one session, for the M1 acceptance check.
struct TranscriptionMetrics: Sendable {
    /// Seconds from the teacher stopping to the final text, for utterances ended by a pause.
    /// Includes the pause the segmenter waits for (0.6 s) to be sure the sentence is over.
    var finalLatencies: [Double] = []
    /// Seconds from a long utterance being cut at the length limit to its final text. Its words were
    /// already on screen as a partial, so this is reported separately rather than held to the pause target.
    var cutFinalLatencies: [Double] = []
    /// Seconds from the newest audio in a partial arriving to its text.
    var partialLatencies: [Double] = []
    var recognizedAudioSeconds: Double = 0
    var computeSeconds: Double = 0
    var repetitionsCollapsed = 0
    /// Results that repeated the vocabulary prompt and were transcribed again without it.
    var contextEchoes = 0
    var errors = 0

    struct Distribution: Codable, Sendable, Equatable {
        var count: Int
        var p50: Double
        var p95: Double
        var max: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            count = sorted.count
            func percentile(_ p: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
            }
            p50 = percentile(0.5)
            p95 = percentile(0.95)
            self.max = sorted.last ?? 0
        }
    }

    struct Report: Codable, Sendable {
        var engine: String
        var audioSeconds: Double
        var finalLatency: Distribution
        var cutFinalLatency: Distribution
        var partialLatency: Distribution
        /// Audio seconds recognized per compute second, partial re-runs included.
        var speedFactor: Double
        var repetitionsCollapsed: Int
        var contextEchoes: Int
        var errors: Int
        var peakMemoryMB: Double
        var sessionDirectory: String
        /// Seconds from a final English segment to its Chinese; nil when translation was off.
        var translationLatency: Distribution?
        var translationErrors: Int?
        /// Questions found and answered; nil when question spotting was off.
        var questions: [QuestionSummary]?
        /// Seconds from a question's segment to the question being found.
        var questionLatency: Distribution?
        /// Seconds from a question being found to the first piece of its answer, and to the whole answer.
        var answerFirstPieceLatency: Distribution?
        var answerTotalLatency: Distribution?
        var questionModelCalls: Int?
        var questionErrors: Int?
        /// Terms in the glossary from the open slides; nil without slides.
        var glossaryTerms: Int?
    }

    struct QuestionSummary: Codable, Sendable {
        var at: TimeInterval
        var quote: String
        var english: String
        var status: String
    }

    func report(engine: String, audioSeconds: Double, peakMemoryMB: Double, sessionDirectory: URL) -> Report {
        Report(
            engine: engine,
            audioSeconds: audioSeconds,
            finalLatency: Distribution(finalLatencies),
            cutFinalLatency: Distribution(cutFinalLatencies),
            partialLatency: Distribution(partialLatencies),
            speedFactor: computeSeconds > 0 ? recognizedAudioSeconds / computeSeconds : 0,
            repetitionsCollapsed: repetitionsCollapsed,
            contextEchoes: contextEchoes,
            errors: errors,
            peakMemoryMB: peakMemoryMB,
            sessionDirectory: sessionDirectory.path
        )
    }
}
