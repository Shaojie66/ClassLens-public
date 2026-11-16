import AppKit
import CryptoKit
import Foundation

/// Turns PowerPoint and Keynote files into PDF by asking PowerPoint (or Keynote) to export them, so the
/// rest of the app only ever deals with PDF. Results are cached by the source file's SHA-256.
enum SlideConverter {
    static let convertibleExtensions: Set<String> = ["ppt", "pptx", "pps", "ppsx", "key"]

    enum Exporter: String, CaseIterable, Sendable {
        case powerPoint = "com.microsoft.Powerpoint"
        case keynote = "com.apple.iWork.Keynote"

        var name: String {
            switch self {
            case .powerPoint: "PowerPoint"
            case .keynote: "Keynote"
            }
        }

        /// AppleScript that opens argv[1] and saves it as PDF at argv[2]; argv[3] is the file name, checked
        /// before anything is saved so a presentation the student already had open is never touched.
        /// On failure it closes only the deck it opened, and quits the app only if it wasn't running before.
        var script: String {
            switch self {
            case .powerPoint:
                """
                -- Closes the presentation with this file name, looked up again by name: a reference kept
                -- from earlier ("presentation 2") doesn't close it reliably.
                on closeDeck(expectedName)
                    tell application id "com.microsoft.Powerpoint"
                        repeat with index from (count of presentations) to 1 by -1
                            if name of presentation index is expectedName then close presentation index saving no
                        end repeat
                    end tell
                end closeDeck

                on run argv
                    set inputFile to POSIX file (item 1 of argv)
                    set outputFile to POSIX file (item 2 of argv)
                    set expectedName to item 3 of argv
                    set wasRunning to application id "com.microsoft.Powerpoint" is running
                    set opened to false
                    try
                        tell application id "com.microsoft.Powerpoint"
                            with timeout of 120 seconds
                                log "step open"
                                open inputFile
                                -- On a cold start the deck appears a few seconds after `open` returns. Find it by
                                -- name rather than taking the active presentation, which may be the student's.
                                -- (PowerPoint's scripting doesn't support `whose` filters on presentations.)
                                set deck to missing value
                                repeat 60 times
                                    repeat with index from 1 to (count of presentations)
                                        if name of presentation index is expectedName then
                                            set deck to presentation index
                                            exit repeat
                                        end if
                                    end repeat
                                    if deck is not missing value then exit repeat
                                    delay 0.5
                                end repeat
                                if deck is missing value then error "PowerPoint 没能打开这个文件"
                                set opened to true
                                log "step save"
                                save deck in outputFile as save as PDF
                            end timeout
                        end tell
                        log "step close"
                        closeDeck(expectedName)
                        tell application id "com.microsoft.Powerpoint"
                            set remaining to {}
                            repeat with index from 1 to (count of presentations)
                                set end of remaining to name of presentation index
                            end repeat
                        end tell
                        log "trace still open: " & (remaining as text)
                    on error message number code
                        if opened then
                            try
                                closeDeck(expectedName)
                            end try
                        end if
                        if not wasRunning then tell application id "com.microsoft.Powerpoint" to quit saving no
                        error message number code
                    end try
                    if not wasRunning then tell application id "com.microsoft.Powerpoint" to quit saving no
                end run
                """
            case .keynote:
                """
                on run argv
                    set inputFile to POSIX file (item 1 of argv)
                    set outputFile to POSIX file (item 2 of argv)
                    set wasRunning to application id "com.apple.iWork.Keynote" is running
                    if not wasRunning then
                        -- Sending `open` while Keynote is still launching fails with -609 (connection invalid).
                        tell application id "com.apple.iWork.Keynote" to launch
                        repeat 60 times
                            if application id "com.apple.iWork.Keynote" is running then exit repeat
                            delay 0.5
                        end repeat
                        delay 2
                    end if
                    tell application id "com.apple.iWork.Keynote"
                        set deck to missing value
                        try
                            with timeout of 120 seconds
                                set deck to open inputFile
                                export deck to outputFile as PDF
                                close deck saving no
                            end timeout
                        on error message number code
                            if deck is not missing value then
                                try
                                    close deck saving no
                                end try
                            end if
                            if not wasRunning then quit saving no
                            error message number code
                        end try
                        if not wasRunning then quit saving no
                    end tell
                end run
                """
            }
        }

        var isInstalled: Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil
        }
    }

    enum Failure: LocalizedError {
        case noExporter
        case notAuthorized(String)
        case failed(String, String)
        case timedOut(String)
        /// Every installed app was tried; one message per app.
        case allFailed([String])

        var errorDescription: String? {
            switch self {
            case .noExporter:
                "要导入 PPT，需要安装 PowerPoint 或 Keynote。也可以先在别处导出成 PDF 再打开。"
            case .notAuthorized(let app):
                "ClassLens 没有控制 \(app) 的权限。请到“系统设置 › 隐私与安全性 › 自动化”里，为 ClassLens 打开 \(app)。"
            case .failed(let app, let message):
                "\(app) 转换失败：\(message)"
            case .timedOut(let app):
                "\(app) 转换超时（3 分钟）。可以先在 \(app) 里手动导出成 PDF 再打开。"
            case .allFailed(let messages):
                "课件转换失败。" + messages.joined(separator: "；")
            }
        }
    }

    static var cacheDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "ClassLens/converted", directoryHint: .isDirectory)
    }

    /// The cached or freshly exported PDF for a slide file. `progress` names the app doing the work.
    static func pdf(for source: URL, progress: @MainActor (String) -> Void) async throws -> URL {
        let data = try Data(contentsOf: source)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let cached = cacheDirectory.appending(path: "\(fingerprint).pdf")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // CLASSLENS_EXPORTER=keynote (or powerPoint) forces one app, for testing each path.
        let forced = ProcessInfo.processInfo.environment["CLASSLENS_EXPORTER"].flatMap { name in
            Exporter.allCases.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        let exporters = (forced.map { [$0] } ?? Exporter.allCases).filter(\.isInstalled)
        guard !exporters.isEmpty else { throw Failure.noExporter }
        var failures: [Failure] = []
        for exporter in exporters {
            await progress(exporter.name)
            let output = cacheDirectory.appending(path: "\(fingerprint).\(exporter.name).partial.pdf")
            try? FileManager.default.removeItem(at: output)
            do {
                try await run(exporter, input: source, output: output)
                guard FileManager.default.fileExists(atPath: output.path) else {
                    throw Failure.failed(exporter.name, "没有生成 PDF 文件")
                }
                try FileManager.default.moveItem(at: output, to: cached)
                return cached
            } catch let failure as Failure {
                // Permission is per app: if PowerPoint is refused, Keynote may still be allowed.
                failures.append(failure)
            }
        }
        if failures.count == 1, let only = failures.first { throw only }
        throw Failure.allFailed(failures.compactMap(\.errorDescription))
    }

    private static func run(_ exporter: Exporter, input: URL, output: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", exporter.script, input.path, output.path, input.lastPathComponent]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
            // A conversion that hangs (for example on a dialog in the other app) is stopped after 3 minutes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                if process.isRunning { process.terminate() }
            }
        }
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ProcessInfo.processInfo.environment["CLASSLENS_TRACE"] == "1" {
            print("convert \(exporter.name) exit \(status):\n\(output)")
        }
        // The script logs "step …" lines before the error; show the error and the step it failed at.
        let lines = output.split(separator: "\n").map(String.init)
        let step = lines.last { $0.hasPrefix("step ") }
        let error = lines.last { !$0.hasPrefix("step ") && !$0.hasPrefix("trace ") } ?? ""
        let message = [error, step.map { "（停在 \($0.dropFirst(5))）" }].compactMap { $0 }.joined()
        guard status == 0 else {
            if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                throw Failure.notAuthorized(exporter.name)
            }
            if process.terminationReason == .uncaughtSignal { throw Failure.timedOut(exporter.name) }
            throw Failure.failed(exporter.name, message.isEmpty ? "退出码 \(status)" : message)
        }
    }
}
