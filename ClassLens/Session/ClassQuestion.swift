import Foundation

/// A question the teacher asked, with the AI's answer as it streams in. Saved to `qa.json`.
struct ClassQuestion: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case answering, answered, failed
    }

    enum Origin: String, Codable, Sendable {
        /// Spotted automatically.
        case detected
        /// The student asked for this line to be answered.
        case manual
        /// The student selected text in the slides and asked about it.
        case selection
        /// The student selected words in a caption and asked about them.
        case caption

        /// Asked by the teacher (spotted or marked by hand), as opposed to the student's own questions.
        var isTeachers: Bool { self == .detected || self == .manual }
    }

    var id = UUID()
    /// The transcript segment the question was asked in.
    var segmentID: UUID
    /// Seconds from the start of the recording.
    var at: TimeInterval
    /// The teacher's words as recognized.
    var quote: String
    var english: String
    var chinese: String
    var origin: Origin
    /// Slide page (1-based) the question is about or was asked on, when slides were open.
    var page: Int?
    var status: Status = .answering
    var answer = ""
    var error: String?
}
