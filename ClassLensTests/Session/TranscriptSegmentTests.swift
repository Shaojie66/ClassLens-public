import Foundation
import Testing
@testable import ClassLens

struct TranscriptSegmentTests {
    @Test func roundTripsThroughJSON() throws {
        let segment = TranscriptSegment(start: 1.5, end: 4.2, text: "A mutex guards shared state.", isFinal: true, translation: "互斥锁保护共享状态。")
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        #expect(decoded == segment)
    }
}
