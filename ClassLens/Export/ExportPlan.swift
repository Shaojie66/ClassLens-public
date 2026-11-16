import Foundation

/// The files one export will create. Names follow `<课程>-W<周>-<日期>-<种类>`; if a file of that name already
/// exists the whole set moves to `-2`, `-3`, …, so nothing in the vault is ever overwritten.
struct ExportPlan: Equatable, Sendable {
    var folder: URL
    var course: String
    var week: Int?
    var lectureDate: Date
    var includeTranscript = true
    var includeAudio: Bool
    var includeSummary: Bool
    /// "" or "-2", "-3"… when the plain names are taken.
    private(set) var suffix = ""

    /// `includeTranscript: false` adds a missing piece (the summary) next to an earlier export under the same names.
    init(folder: URL, course: String, week: Int?, lectureDate: Date, includeTranscript: Bool = true, includeAudio: Bool, includeSummary: Bool) {
        self.folder = folder
        self.includeTranscript = includeTranscript
        self.course = course
        self.week = week
        self.lectureDate = lectureDate
        self.includeAudio = includeAudio
        self.includeSummary = includeSummary
        resolveConflicts()
    }

    var dateText: String {
        lectureDate.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    var weekText: String? { week.map { String(format: "W%02d", $0) } }

    var stem: String {
        [course, weekText, dateText].compactMap { $0 }.joined(separator: "-") + suffix
    }

    var transcriptURL: URL { folder.appending(path: "转写/\(stem)-课堂转写.md") }
    var audioURL: URL { folder.appending(path: "录音/\(stem)-课堂录音.m4a") }
    var summaryURL: URL { folder.appending(path: "AI总结/\(stem)-AI总结.md") }

    var files: [URL] {
        (includeTranscript ? [transcriptURL] : []) + (includeAudio ? [audioURL] : []) + (includeSummary ? [summaryURL] : [])
    }

    /// True when the plain names were taken and a numbered set is used instead.
    var isRenamed: Bool { !suffix.isEmpty }

    private mutating func resolveConflicts() {
        var number = 1
        while files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            number += 1
            suffix = "-\(number)"
        }
    }
}
