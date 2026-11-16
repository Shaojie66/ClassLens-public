import AppKit
import SwiftUI

/// Live captions: finished utterances in full color, the one being spoken in gray.
struct TranscriptPane: View {
    @Environment(AppModel.self) private var model

    private var playingSegmentID: UUID? {
        guard model.reviewing != nil, model.isPlaying else { return nil }
        return model.segments.last { $0.start <= model.playbackTime }?.id
    }

    var body: some View {
        if model.segments.isEmpty {
            ContentUnavailableView(
                model.isListening ? "正在听…" : (model.reviewing != nil ? "这节课没有字幕" : "还没有字幕"),
                systemImage: "captions.bubble",
                description: Text(model.isListening ? "老师开口后，字幕会在一两秒内出现。" : "开始录音后，英文原文和中文翻译会在这里逐句出现。")
            )
        } else {
            ScrollViewReader { proxy in
                List(model.segments) { segment in
                    SegmentRow(segment: segment, translating: model.translating.contains(segment.id), isQuestion: model.isQuestion(segment.id), isPlaying: model.reviewing != nil && model.isPlaying && segment.start <= model.playbackTime && model.playbackTime < segment.end)
                        .id(segment.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if model.reviewing != nil { model.play(from: segment.start) }
                        }
                        .contextMenu {
                            if segment.isFinal, !model.isQuestion(segment.id) {
                                Button("让 AI 回答这句", systemImage: "questionmark.bubble") { model.answerManually(segment.id) }
                                    .disabled(!model.hasAPIKey)
                            }
                            Button("复制", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString([segment.text, segment.translation].compactMap { $0 }.joined(separator: "\n"), forType: .string)
                            }
                        }
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .onChange(of: model.segments.last) { _, last in
                    guard let last, model.reviewing == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: playingSegmentID) { _, id in
                    // While playing back, keep the spoken line in view.
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

private struct SegmentRow: View {
    /// A selectable caption line wired to the student's selection actions.
    private func caption(_ text: String, color: NSColor) -> some View {
        let id = segment.id
        return SelectableText(text: text, color: color, onSelection: { selected in
            model.selectionChanged(selected.map { TextSelection(text: $0, source: .caption(segmentID: id)) })
        }, onAction: { item, selected in
            let selection = TextSelection(text: selected, source: .caption(segmentID: id))
            switch item {
            case .explain: model.ask(selection, action: .explain)
            case .translate: model.ask(selection, action: .translate)
            case .custom: model.pendingSelection = selection
            }
        }, extraMenu: model.isQuestion(id) ? [] : [("让 AI 回答这句（当作老师提问）", { model.answerManually(id) })])
    }

    @Environment(AppModel.self) private var model
    let segment: TranscriptSegment
    let translating: Bool
    let isQuestion: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Duration.seconds(segment.start).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if isQuestion {
                    Image(systemName: "questionmark.bubble.fill")
                        .foregroundStyle(.tint)
                        .help("老师在提问，答案在“问答”里")
                }
            }
            .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                if segment.isFinal {
                    caption(segment.text, color: .labelColor)
                } else {
                    // Partials change every second; selecting in them would lose the selection.
                    Text(segment.text).font(.body).foregroundStyle(.secondary)
                }
                if let translation = segment.translation {
                    caption(translation, color: .secondaryLabelColor)
                } else if translating {
                    Text("翻译中…").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .help(model.reviewing != nil ? "点时间戳从这里播放；选中文字可以让 AI 解释" : "选中文字可以让 AI 解释（⌘E）")
        .background(isPlaying ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
    }
}
