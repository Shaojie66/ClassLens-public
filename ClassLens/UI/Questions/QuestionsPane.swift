import SwiftUI

/// The teacher's questions with AI answers, newest first.
struct QuestionsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let since = model.breakSince {
                BreakBanner(since: since)
                Divider()
            }
            questionList
        }
    }

    @ViewBuilder private var questionList: some View {
        if model.questions.isEmpty {
            ContentUnavailableView(
                "还没有提问",
                systemImage: "questionmark.bubble",
                description: Text(model.questionsEnabled
                    ? "老师向全班提问时，问题和参考答案会出现在这里。漏掉的问题可以在字幕上右键，选“让 AI 回答这句”。"
                    : "提问识别已关闭，可以在“选项”菜单里打开。")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.questions.reversed()) { question in
                        QuestionCard(question: question)
                    }
                }
                .padding(12)
            }
        }
    }
}

/// Shown while question spotting is paused because the teacher called a break.
private struct BreakBanner: View {
    @Environment(AppModel.self) private var model
    let since: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cup.and.saucer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("课间休息，暂停识别提问")
                    .font(.callout.weight(.medium))
                Text("从 \(Duration.seconds(since).formatted(.time(pattern: .minuteSecond))) 起；听到老师宣布回来上课时自动恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("继续识别") { model.endBreak() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct QuestionCard: View {
    let question: ClassQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Duration.seconds(question.at).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                switch question.origin {
                case .detected: EmptyView()
                case .manual: Text("手动").font(.caption).foregroundStyle(.secondary)
                case .selection: Label("课件划词", systemImage: "text.cursor").font(.caption).foregroundStyle(.secondary)
                case .caption: Label("字幕划词", systemImage: "captions.bubble").font(.caption).foregroundStyle(.secondary)
                }
                if let page = question.page {
                    Text("第 \(page) 页").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch question.status {
                case .answering: ProgressView().controlSize(.small)
                case .answered: EmptyView()
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Text(question.chinese.isEmpty ? question.english : question.chinese)
                .font(.headline)
            Text(question.origin.isTeachers ? "“\(question.quote)”" : question.quote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Divider()
            if let error = question.error {
                Text(error).foregroundStyle(.orange)
            } else if question.answer.isEmpty {
                Text("正在生成答案…").foregroundStyle(.tertiary)
            } else {
                Text(Self.markdown(question.answer))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
