import SwiftUI

/// Shown above the captions while reviewing a past lecture: what it is, and playback.
struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    let session: LoadedSession
    @State private var exporting = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(model.player == nil)
            .help(model.player == nil ? "这节课没有录音文件" : "播放或暂停；点任意一句字幕从那里开始播放")
            VStack(alignment: .leading, spacing: 1) {
                Text(session.summary.title).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(Duration.seconds(model.playbackTime).formatted(.time(pattern: .hourMinuteSecond))) / \(Duration.seconds(session.summary.duration).formatted(.time(pattern: .hourMinuteSecond)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("导出", systemImage: "square.and.arrow.up") { exporting = true }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("导出到 Obsidian：转写、录音和 AI 课后总结")
            Button("回到实时") { model.leaveReview() }
                .buttonStyle(.borderless)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $exporting) { ExportSheet(session: session) }
    }
}
