// Transcribes a file with Apple SpeechAnalyzer and prints "[start-end] text" per final result.
// Usage: swift Bench/speechanalyzer.swift <audio> [terms.txt]
import AVFoundation
import Foundation
import Speech

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: speechanalyzer <audio> [terms.txt]") }
let url = URL(fileURLWithPath: args[1])
let terms = args.count >= 3 ? (try String(contentsOfFile: args[2], encoding: .utf8)).split(separator: "\n").map(String.init) : []

let locale = Locale(identifier: "en-US")
let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    FileHandle.standardError.write("downloading en-US speech assets…\n".data(using: .utf8)!)
    try await request.downloadAndInstall()
}
let analyzer = SpeechAnalyzer(modules: [transcriber])
if !terms.isEmpty {
    let context = AnalysisContext()
    context.contextualStrings[.general] = terms
    try await analyzer.setContext(context)
}

let started = Date()
let collector = Task {
    var lines: [String] = []
    for try await result in transcriber.results where result.isFinal {
        let start = result.range.start.seconds, end = result.range.end.seconds
        lines.append(String(format: "[%.1f-%.1f] ", start, end) + String(result.text.characters))
    }
    return lines
}
let file = try AVAudioFile(forReading: url)
if let last = try await analyzer.analyzeSequence(from: file) {
    try await analyzer.finalizeAndFinish(through: last)
} else {
    await analyzer.cancelAndFinishNow()
}
let lines = try await collector.value
print(lines.joined(separator: "\n"))
let duration = Double(file.length) / file.processingFormat.sampleRate
FileHandle.standardError.write(String(format: "audio %.0fs, took %.1fs (%.1fx realtime)\n", duration, Date().timeIntervalSince(started), duration / Date().timeIntervalSince(started)).data(using: .utf8)!)
