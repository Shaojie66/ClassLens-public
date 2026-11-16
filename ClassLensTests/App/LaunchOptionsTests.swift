import Foundation
import Testing
@testable import ClassLens

struct LaunchOptionsTests {
    @Test func parsesHeadlessReplay() {
        let options = LaunchOptions(arguments: ["ClassLens", "--replay", "/tmp/a.wav", "--replay-start", "600", "--replay-duration", "120", "--replay-speed", "2", "--metrics-out", "/tmp/m.json", "--quit-when-done"])
        #expect(options.replay?.path == "/tmp/a.wav")
        #expect(options.replayStart == 600)
        #expect(options.replayDuration == 120)
        #expect(options.replaySpeed == 2)
        #expect(options.metricsOut?.path == "/tmp/m.json")
        #expect(options.quitWhenDone)
    }

    @Test func parsesExportOptions() {
        let options = LaunchOptions(arguments: ["ClassLens", "--export", "latest", "--lecture-date", "2026-11-02", "--no-summary"])
        #expect(options.export == "latest")
        #expect(options.noSummary)
        #expect(options.lectureDate.map { TranscriptMarkdown.day($0) } == "2026-11-02")
    }

    @Test func ignoresXcodeArguments() {
        let options = LaunchOptions(arguments: ["ClassLens", "-NSDocumentRevisionsDebugMode", "YES"])
        #expect(options == LaunchOptions(arguments: ["ClassLens"]))
    }
}
