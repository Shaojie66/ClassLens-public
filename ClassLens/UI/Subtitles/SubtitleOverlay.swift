import SwiftUI

/// A floating window with the newest captions, readable over full-screen slides.
struct SubtitleOverlay: View {
    static let windowID = "subtitles"

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line = latest {
                Text(line.text)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(line.isFinal ? .primary : .secondary)
                if let translation = translation {
                    Text(translation)
                        .font(.system(size: 22, weight: .semibold))
                }
            } else {
                Text(model.isListening ? "正在听…" : "开始录音后，字幕会显示在这里")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(16)
        .background(.regularMaterial)
    }

    /// The utterance being spoken, else the last finished one.
    private var latest: TranscriptSegment? { model.segments.last }

    /// Chinese of the newest translated line, so the Chinese doesn't vanish while the next sentence is spoken.
    private var translation: String? {
        model.segments.last(where: { $0.translation != nil })?.translation
    }
}
