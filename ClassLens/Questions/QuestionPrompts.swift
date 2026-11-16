import Foundation

/// Prompts for spotting the teacher's real questions and answering them.
enum QuestionPrompts {
    // MARK: Spotting

    static let findSystem = """
    You read a short stretch of a live university lecture transcript (English speech recognition) and decide \
    which questions the teacher is really asking the students to answer. Reply with a JSON object only:
    {"questions": [{"line": 12, "kind": "directed", "signal": "student-answer", "evidence": "...", "english": "...", "chinese": "..."}]}

    Each line shows its number, time, the pause after it in seconds, and the text. Lines marked with * contain \
    question-like sentences. For every question in a marked line, give one entry with "kind":
    - "directed": the teacher stops and expects the class to answer.
    - "one-on-one": the teacher is talking with one person, not the class: a student at their desk during a \
    lab, a teaching assistant, someone who came up after class. These are personal or arranging questions \
    ("are you on the master's programme?", "could you cover Thursday's session?", "is your code running \
    now?") in a back-and-forth where that person's short replies ("yeah", a name, "it's in this building") \
    are conversation, not answers from the class. Questions about the teacher's own schedule, rooms or staff \
    are "one-on-one" or "logistics", never "directed".
    - "rhetorical": the teacher asks and carries on explaining, answers it, or uses it to introduce the next point. \
    A question that is one of the options in an explanation ("is A the same as B, or does it have a smaller \
    variance?") is rhetorical. So are recaps ("so what have we done so far?") and questions the teacher answers \
    in the next line ("What's the difference?" → "The difference is…").
    - "check-in": tag questions and checks such as "…, right?", "does that make sense?", "can you hear me?", \
    "is it better for you?".
    - "logistics": about breaks, votes on when to stop, the room, screen, homework deadlines or similar.
    - "statement": not really a question. Speech recognition often puts a question mark on a statement or on a \
    fragment that continues the previous line: "Which we don't know yet.", "…the value of t. / Is the lowest \
    alpha that still leads to rejection?" (a definition: "[it] is the lowest alpha…"), "What you fine folks did \
    from here." Read the line together with the line before it.
    - "unclear": too garbled to tell what is asked ("So, but this is went to where to from?").

    For "directed", "signal" names the strongest evidence from what happens next, and "evidence" quotes it:
    - "student-answer": short, garbled or off-topic lines right after it that fit as students in the class \
    answering from far away, which the recognizer catches badly (the replies of someone the teacher is talking \
    with one-on-one don't count) (for example "One.", "Take it off. Keep it in.", "To each side.");
    - "teacher-repeats": the teacher repeats or rephrases the question, or asks a follow-up to the same point;
    - "invites-answer": the teacher invites answers or gives a hint ("let's go", "anyone?", "tell me", \
    "think about it", "a tip: I mentioned it earlier");
    - "reacts-to-answer": the teacher reacts to an answer ("exactly", "good", "yes, and…");
    - "silence-only": nothing but a pause or laughter, "okay", "all right", or an unrelated remark.
    A pause alone happens all the time in a lecture (changing slides, laughter, thinking) and is not enough: \
    with only a pause, the signal is "silence-only". If the teacher's next words simply continue the explanation \
    ("So…", "It means…", "Which is…"), the question is "rhetorical". When unsure, choose "rhetorical".

    Several questions in a row about the same thing are one entry, on the line of the last of them.
    For "directed" only, also give "english": the question as one clear, self-contained English sentence \
    (fix obvious recognition errors), and "chinese": the same question in Simplified Chinese.
    Skip questions already listed as found. If there are no questions, reply {"questions": []}.
    """

    /// `pause` is the silence after a line in seconds; nil when the next line hasn't come yet.
    /// `quietAfter` says the window ended because nobody spoke for that many seconds after the last line.
    static func findUser(lines: [(number: Int, time: TimeInterval, pause: Double?, text: String, marked: Bool)], found: [String], quietAfter: Int? = nil) -> String {
        var transcript = lines.map { line in
            let pause = line.pause.map { String(format: "%.1fs", max(0, $0)) } ?? "?"
            return "\(line.marked ? "*" : " ")[\(line.number)] \(clock(line.time)) (pause \(pause)) \(line.text)"
        }.joined(separator: "\n")
        if let quietAfter {
            transcript += "\n(no speech for at least \(quietAfter) s after the last line)"
        }
        let listed = found.isEmpty ? "(none)" : found.map { "- \($0)" }.joined(separator: "\n")
        return "Questions already found:\n\(listed)\n\nTranscript:\n\(transcript)"
    }

    // MARK: Answering

    static let answerSystem = """
    你是一名计算机与数据科学方向的助教，帮一名中国学生在英文授课的课堂上回答老师刚提出的问题。

    按下面的格式用 Markdown 回答，总共不超过 200 字：
    **答案**：一两句话直接给出结论。
    **可以这样回答**：一句简洁的英文，学生可以照着举手说出来。
    **解释**：两到四句，讲清楚为什么，必要时给出公式或简短例子。

    要求：
    - 结合课堂上下文理解老师问的是什么，用老师的记号和说法（例如老师用 θ 和 H0，就沿用）。
    - 技术术语第一次出现时附英文，例如 原假设（null hypothesis）。
    - 转录来自语音识别，可能有听错的词，按课程内容推断原意。和课程内容明显不搭的词（比如统计课上出现 grass、license），多半是读音相近的术语被听错了（graph、null），按术语理解，不要把它当成老师的比喻或原意来解释。
    - 不确定时直说哪一部分不确定，不要编造。
    """

    static func answerUser(question: String, quote: String, context: [String], glossary: [String] = [], slide: String? = nil) -> String {
        var parts: [String] = []
        if !glossary.isEmpty { parts.append("课程术语：" + glossary.joined(separator: ", ")) }
        if let slide, !slide.isEmpty { parts.append("学生此时打开的课件页：\n" + slide) }
        if !context.isEmpty { parts.append("最近几分钟的课堂转录：\n" + context.joined(separator: "\n")) }
        parts.append("老师的原话：\(quote)")
        parts.append("要回答的问题：\(question)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: Selection

    static let selectionSystem = """
    你是一名计算机与数据科学方向的助教。学生在课上看课件时选中了一段内容，并就它提了一个问题。

    要求：
    - 用中文回答，紧扣选中的内容；需要时结合这一页的其余内容和课堂转录。
    - 技术术语第一次出现时附英文，例如 原假设（null hypothesis）；公式和符号沿用课件的写法。
    - 简洁：先一两句话给结论，再用几句话解释，必要时举一个小例子。总共不超过 250 字，用 Markdown。
    - 不确定时直说，不要编造课件里没有的内容。
    """

    static func selectionUser(question: String, selection: String, page: Int, pageText: String, context: [String], glossary: [String]) -> String {
        var parts: [String] = []
        if !glossary.isEmpty { parts.append("课程术语：" + glossary.joined(separator: ", ")) }
        parts.append("课件第 \(page) 页全文：\n" + pageText)
        if !context.isEmpty { parts.append("最近的课堂转录：\n" + context.joined(separator: "\n")) }
        parts.append("学生选中的内容：\n" + selection)
        parts.append("学生的问题：" + question)
        return parts.joined(separator: "\n\n")
    }

    // MARK: Caption selection

    static let captionSystem = """
    你是一名计算机与数据科学方向的助教。学生在课堂字幕里选中了老师说的几个词或一段话，并就它提了一个问题。

    要求：
    - 用中文回答，紧扣选中的内容，先说清它在老师这句话里是什么意思，再结合前后几句和课件解释。
    - 字幕来自语音识别，可能有听错的词。和课程内容明显不搭的词（比如统计课上的 grass、license）多半是读音相近的术语被听错了（graph、null），按术语理解，并说明“原话可能是……”。
    - 技术术语第一次出现时附英文；公式和符号沿用课件的写法。
    - 简洁：先一两句话给结论，再用几句话解释。总共不超过 200 字，用 Markdown。
    - 不确定时直说，不要编造。
    """

    static func captionUser(question: String, selection: String, sentence: String, translation: String?, around: [String], slide: String?, glossary: [String]) -> String {
        var parts: [String] = []
        if !glossary.isEmpty { parts.append("课程术语：" + glossary.joined(separator: ", ")) }
        if let slide, !slide.isEmpty { parts.append("老师当时讲的课件页：\n" + slide) }
        if !around.isEmpty { parts.append("前后几句字幕：\n" + around.joined(separator: "\n")) }
        parts.append("学生选中内容所在的那句：\n" + sentence + (translation.map { "\n（机器翻译：\($0)）" } ?? ""))
        parts.append("学生选中的内容：" + selection)
        parts.append("学生的问题：" + question)
        return parts.joined(separator: "\n\n")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
