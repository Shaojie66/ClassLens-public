import Foundation

/// What the live pipeline reports while listening.
enum TranscriptionEvent: Sendable, Equatable {
    /// The utterance still being spoken; replaces the earlier partial with the same id.
    case partial(TranscriptSegment)
    /// The finished utterance; no further events carry its id. Empty text means nothing was said.
    case final(TranscriptSegment)
    case failed(String)
}

/// A speech recognizer that turns one utterance of 16 kHz mono audio into text.
/// Implementations: Qwen3-ASR (main), Parakeet (fallback), fakes in tests.
protocol TranscriptionEngine: Sendable {
    var name: String { get }
    /// `context` carries course terms that bias recognition, e.g. from the open slides.
    func transcribe(_ samples: [Float], context: String) async throws -> String
}
