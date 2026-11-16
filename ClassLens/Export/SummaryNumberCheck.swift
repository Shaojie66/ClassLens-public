import Foundation

/// Flags numbers the summary states as fact that the transcript and slides don't contain.
///
/// The prompt already asks for inferred numbers to go under 待核对, but the model still wrote a misheard
/// "fifteen" as 50 in the Week 7 summary, so this checks it mechanically. Each line of the summary is checked
/// against the transcript near the times it cites (±2 min; the whole transcript when it cites none) and
/// all slide text. Numbers the model already lists under 待核对 are skipped, as are integers up to 10
/// (subscripts, n − 1, step numbers), which would mostly be noise.
enum SummaryNumberCheck {
    static let section = "## 待核对"
    static let nearby: TimeInterval = 120

    /// The summary with lines under 待核对 listing numbers it couldn't find in the sources, or that sit next
    /// to their teen/ty twin in the transcript.
    static func annotate(_ summary: String, segments: [TranscriptSegment], slides: String) -> String {
        let found = unsupported(in: summary, segments: segments, slides: slides)
        func place(_ item: Unsupported) -> String { item.near.map { "（\(TranscriptMarkdown.clock($0)) 附近）" } ?? "" }
        let missing = found.filter { $0.twin == nil }.map { "`\($0.number)`" + place($0) }
        let twins = found.compactMap { item in item.twin.map { "`\(item.number)`" + place(item) + "，转写里也有 \($0)" } }
        var notes: [String] = []
        if !missing.isEmpty {
            notes.append("- 程序核对：下面这些数字在所引时间附近的转写和课件里都找不到原文，可能是推断出来的或识别错误，请对照录音：" + missing.joined(separator: "、"))
        }
        if !twins.isEmpty {
            notes.append("- 程序核对：下面这些数字附近的转写里有读音相近的另一个数（fifteen / fifty 这类最容易听混），请对照录音确认是哪一个：" + twins.joined(separator: "；"))
        }
        guard !notes.isEmpty else { return summary }
        var lines = summary.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == section }) {
            var end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.insert(contentsOf: notes, at: end)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += ["", section] + notes
        }
        return lines.joined(separator: "\n")
    }

    struct Unsupported: Equatable {
        var number: String
        /// First time the line cites, if any.
        var near: TimeInterval?
        /// The number's teen/ty twin when that, not the number itself, is what's missing doubt about.
        var twin: String?

        init(number: String, near: TimeInterval?, twin: String? = nil) {
            self.number = number
            self.near = near
            self.twin = twin
        }
    }

    /// 13–19 and 30–90 sound alike and are the recognizer's most common number mix-up.
    static func twin(of number: String) -> String? {
        guard let value = Int(number) else { return nil }
        switch value {
        case 13...19: return String((value - 10) * 10)
        case 30, 40, 50, 60, 70, 80, 90: return String(value / 10 + 10)
        default: return nil
        }
    }

    static func unsupported(in summary: String, segments: [TranscriptSegment], slides: String) -> [Unsupported] {
        let lines = summary.components(separatedBy: "\n")
        let start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == section }
        let end = start.flatMap { start in lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } } ?? lines.endIndex
        let flagged = start.map { Set(lines[$0..<end].flatMap { stated(in: $0).numbers }) } ?? []
        let slideNumbers = spoken(in: slides)
        let everything = slideNumbers.union(spoken(in: segments.map(\.text).joined(separator: "\n")))

        var result: [Unsupported] = []
        for (index, line) in lines.enumerated() {
            if let start, index >= start, index < end { continue }
            let (numbers, times) = stated(in: line)
            guard !numbers.isEmpty else { continue }
            let sources = times.isEmpty ? everything : slideNumbers.union(spoken(in: segments
                .filter { segment in times.contains { abs(segment.start - $0) <= nearby || (segment.start <= $0 && $0 <= segment.end) } }
                .map(\.text).joined(separator: "\n")))
            for number in numbers where !flagged.contains(number) && !result.contains(where: { $0.number == number }) {
                if !sources.contains(number) {
                    result.append(Unsupported(number: number, near: times.first))
                } else if let twin = twin(of: number), sources.contains(twin), !flagged.contains(twin) {
                    result.append(Unsupported(number: number, near: times.first, twin: twin))
                }
            }
        }
        return result
    }

    // MARK: Numbers the summary states

    /// Numbers written in a summary line, and the times it cites. Times, page numbers and week numbers are
    /// references rather than claims, so they're removed first.
    static func stated(in line: String) -> (numbers: [String], times: [TimeInterval]) {
        var text = line
        let times = matches(of: #"\b(\d{1,2}):([0-5]\d)(?::([0-5]\d))?\b"#, in: text).map { groups -> TimeInterval in
            let parts = groups.compactMap { $0.flatMap { Double($0) } }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        for pattern in [#"\b\d{1,2}:[0-5]\d(?::[0-5]\d)?\b"#, #"第\s*\d+\s*[页周节讲章]"#, #"\d+\s*页"#, #"\bp\.\s*\d+"#, #"\b[Ww]eek\s*\d+"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Digits glued to a letter are names and subscripts (H0, x1, μ0), not values.
        let numbers = matches(of: #"(?<![\p{L}\d.,_\\])\d{1,3}(?:,\d{3})+(?:\.\d+)?(?![\d])|(?<![\p{L}\d._\\])\d+(?:\.\d+)?(?![\d])"#, in: text)
            .compactMap { $0.first ?? nil }
            .compactMap { canonical($0.replacingOccurrences(of: ",", with: "")) }
            .filter { number in
                guard let value = Double(number) else { return false }
                return value > 10 || value != value.rounded()
            }
        return (numbers, times)
    }

    // MARK: Numbers the sources contain

    /// Numbers in transcript or slide text, written in digits or spoken as English words. A percentage and
    /// its fraction count as the same number (5 and 0.05).
    static func spoken(in text: String) -> Set<String> {
        var values: [Decimal] = []
        let cleaned = text.lowercased().replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
        for match in matches(of: #"\d*\.?\d+"#, in: cleaned) {
            if let digits = match.first ?? nil, let value = Decimal(string: digits) { values.append(value) }
        }
        let words = cleaned.split(whereSeparator: { !$0.isLetter }).map(String.init)
        values += NumberWords.values(in: words)
        return Set(values.flatMap { [$0, $0 * 100, $0 / 100] }.compactMap { canonical("\($0)") })
    }

    /// "0.050" → "0.05", "120.0" → "120".
    static func canonical(_ number: String) -> String? {
        guard let value = Decimal(string: number) else { return nil }
        return "\(value)"
    }

    private static func matches(of pattern: String, in text: String) -> [[String?]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).dropFirst(match.numberOfRanges > 1 ? 1 : 0).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }
}

/// Reads spoken English numbers ("seventy nine point five", "one hundred and twenty") from words.
enum NumberWords {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    /// Digits after "point"; "oh" only counts there, elsewhere it's an interjection.
    private static func digit(_ word: String) -> Int? {
        word == "oh" ? 0 : units[word].flatMap { $0 < 10 ? $0 : nil }
    }
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000]

    /// Every number spoken in `words`. Words that can't continue the current number start a new one, so
    /// "seventy eight seventy six" reads as 78 and 76.
    static func values(in words: [String]) -> [Decimal] {
        var result: [Decimal] = []
        var total = 0, current = 0
        var active = false
        var index = 0

        func close() {
            if active { result.append(Decimal(total + current)) }
            total = 0
            current = 0
            active = false
        }

        while index < words.count {
            let word = words[index]
            // After a scale the last two digits are free ("one hundred five"); after a bare tens word only
            // the ones digit is ("seventy nine").
            let afterScale = current % 100 == 0 && (current > 0 || total > 0)
            let bareTens = current % 100 >= 20 && current % 10 == 0
            if let unit = units[word] {
                if active, !(afterScale || (bareTens && unit < 10)) { close() }
                current += unit
                active = true
            } else if let ten = tens[word] {
                if active, !afterScale { close() }
                current += ten
                active = true
            } else if let scale = scales[word], active || word == "hundred" {
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
                active = true
            } else if word == "and", active, total + current >= 100, index + 1 < words.count,
                      units[words[index + 1]] != nil || tens[words[index + 1]] != nil {
                // "one hundred and twenty"
            } else if word == "point", index + 1 < words.count, digit(words[index + 1]) != nil {
                var digits = ""
                var next = index + 1
                while next < words.count, let value = digit(words[next]) {
                    digits += String(value)
                    next += 1
                }
                if let value = Decimal(string: "\(active ? total + current : 0).\(digits)") { result.append(value) }
                total = 0
                current = 0
                active = false
                index = next
                continue
            } else {
                close()
            }
            index += 1
        }
        close()
        return result
    }
}
