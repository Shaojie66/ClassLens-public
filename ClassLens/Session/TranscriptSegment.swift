import Foundation

/// One recognized span of the lecture. Partial segments are replaced in place until `isFinal`.
struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var isFinal: Bool
    /// Chinese translation, filled in once the segment is final.
    var translation: String?
}
