import AppKit
import SwiftUI

/// Left column: the live view and every saved lecture, newest first.
struct HistorySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""
    @State private var deleting: SessionSummary?

    var body: some View {
        List(selection: selection) {
            Section("现在") {
                Label(model.isListening ? "正在录音" : "实时字幕", systemImage: model.isListening ? "record.circle.fill" : "waveform")
                    .foregroundStyle(model.isListening ? .red : .primary)
                    .tag(Optional<UUID>.none)
            }
            Section("以前的课") {
                if model.history.isEmpty {
                    Text("录完的课会出现在这里").foregroundStyle(.secondary)
                }
                ForEach(model.history) { summary in
                    HistoryRow(summary: summary)
                        .tag(Optional(summary.id))
                        .contextMenu {
                            Button("重命名…") {
                                newTitle = summary.title
                                renaming = summary
                            }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([summary.directory]) }
                            Divider()
                            Button("删除…", role: .destructive) { deleting = summary }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.isListening)
        .onAppear { model.refreshHistory() }
        .alert("重命名这节课", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { if let renaming { model.rename(renaming, to: newTitle) } }
        }
        .confirmationDialog("删除“\(deleting?.title ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("移到废纸篓", role: .destructive) { if let deleting { model.delete(deleting) } }
        } message: {
            Text("录音、字幕和问答会一起移到废纸篓，需要时可以从废纸篓找回。")
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.reviewing?.summary.id },
            set: { id in
                if let id, let summary = model.history.first(where: { $0.id == id }) {
                    Task { await model.review(summary) }
                } else {
                    model.leaveReview()
                }
            }
        )
    }
}

private struct HistoryRow: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title).lineLimit(2)
            HStack(spacing: 6) {
                Text(summary.meta.createdAt.formatted(.dateTime.month().day()))
                Text(Duration.seconds(summary.duration).formatted(.time(pattern: .hourMinute)))
                if summary.questionCount > 0 {
                    Label("\(summary.questionCount)", systemImage: "questionmark.bubble").labelStyle(.titleAndIcon)
                }
                if summary.meta.isReplay {
                    Text("回放").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
