import Foundation

/// Command-line options for headless verification, see CLAUDE.md:
/// `--replay <file> [--replay-start s] [--replay-duration s] [--replay-speed x] [--metrics-out path] [--quit-when-done]`
/// `--bench-engine <file> [--replay-start s]` times the recognizer alone on slices of 2–15 s and quits.
/// `--asr-only` turns off translation and question spotting for this run.
/// `--document <pdf>` opens slides (and builds their glossary) before anything else runs.
/// `--eval-slides <transcript.jsonl>` (with `--document`) prints the tracked slide after each segment and quits.
/// `--review latest|<session id> [--play-from s] [--report-after s]` opens a saved lecture for review,
/// optionally playing; `--report-after` prints the review state after that many seconds and quits.
/// `--export latest|<session id> [--export-folder dir] [--lecture-date yyyy-mm-dd] [--no-audio] [--no-summary]`
/// exports to Obsidian and quits; `--summary-only` adds just the AI summary next to an earlier export.
/// `--eval-questions <transcript.jsonl>` runs question spotting over a saved transcript, prints what it finds as JSON lines, and quits.
struct LaunchOptions: Equatable {
    var replay: URL?
    var replayStart: TimeInterval = 0
    var replayDuration: TimeInterval?
    var replaySpeed: Double = 1
    var metricsOut: URL?
    var quitWhenDone = false
    var benchEngine: URL?
    var asrOnly = false
    var document: URL?
    var evalSlides: URL?
    var review: String?
    var playFrom: TimeInterval?
    var reportAfter: TimeInterval?
    var export: String?
    var exportFolder: URL?
    var noAudio = false
    var noSummary = false
    var lectureDate: Date?
    var summaryOnly = false
    var evalQuestions: URL?

    init(arguments: [String] = CommandLine.arguments) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--replay": replay = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--replay-start": replayStart = iterator.next().flatMap(Double.init) ?? 0
            case "--replay-duration": replayDuration = iterator.next().flatMap(Double.init)
            case "--replay-speed": replaySpeed = iterator.next().flatMap(Double.init) ?? 1
            case "--metrics-out": metricsOut = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--quit-when-done": quitWhenDone = true
            case "--bench-engine": benchEngine = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--asr-only": asrOnly = true
            case "--document": document = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--eval-slides": evalSlides = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--review": review = iterator.next()
            case "--play-from": playFrom = iterator.next().flatMap(Double.init)
            case "--report-after": reportAfter = iterator.next().flatMap(Double.init)
            case "--export": export = iterator.next()
            case "--export-folder": exportFolder = iterator.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--no-audio": noAudio = true
            case "--no-summary": noSummary = true
            case "--summary-only": summaryOnly = true
            case "--lecture-date": lectureDate = iterator.next().flatMap { try? Date($0, strategy: .iso8601.year().month().day().dateSeparator(.dash)) }
            case "--eval-questions": evalQuestions = iterator.next().map { URL(fileURLWithPath: $0) }
            default: continue
            }
        }
    }
}
