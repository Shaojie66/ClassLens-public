import SwiftUI

/// Main window: slides on the left, live captions and Q&A on the right.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Three native columns: history, slides, captions. (An HSplitView nested in the detail column laid
        // its right pane out wider than the window, clipping captions and the review bar.)
        NavigationSplitView {
            HistorySidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            DocumentPane()
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
        } detail: {
            SidePane()
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { WorkspaceToolbar() }
        .sheet(item: Bindable(model).pendingSelection) { selection in
            SelectionQuestionSheet(selection: selection)
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
            }
        }
    }
}

/// Captions and Q&A share the right side; a new question shows as a count on its tab.
private struct SidePane: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.captions

    private enum Tab: Hashable {
        case captions, questions
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.reviewing {
                ReviewBar(session: session)
                Divider()
            }
            Picker("", selection: $tab) {
                Text("字幕").tag(Tab.captions)
                Text(model.unseenQuestions > 0 && tab != .questions ? "问答 (\(model.unseenQuestions) 新)" : "问答 (\(model.questions.count))").tag(Tab.questions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            Group {
                switch tab {
                case .captions: TranscriptPane()
                case .questions: QuestionsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: tab) { _, new in
            if new == .questions { model.unseenQuestions = 0 }
        }
        .onChange(of: model.showQuestionsTab) { _, show in
            guard show else { return }
            tab = .questions
            model.showQuestionsTab = false
        }
    }
}

private struct WorkspaceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            EngineStatusView()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isListening {
                LevelMeter(level: model.level)
                    .frame(width: 60, height: 6)
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("打开课件", systemImage: "doc.badge.plus") { model.chooseDocument() }
                .help("打开 PPT、Keynote 或 PDF 课件")
            Button("字幕浮窗", systemImage: "captions.bubble") {
                openWindow(id: SubtitleOverlay.windowID)
            }
            .help("打开置顶的字幕浮窗，全屏看课件时也能看到字幕")
            Menu("选项", systemImage: "slider.horizontal.3") {
                @Bindable var model = model
                Toggle("实时翻译成中文", isOn: $model.translationEnabled)
                Toggle("识别老师提问并自动回答", isOn: $model.questionsEnabled)
                Toggle("课件跟随老师翻页", isOn: $model.followTeacher)
                Toggle("教室麦克风模式（降噪 + 自动增益）", isOn: $model.classroomMicrophone)
                Divider()
                Button("回放录音文件…") { model.chooseReplayFile() }
                    .disabled(model.activity != .idle)
            }
            Button {
                model.toggleMicrophone()
            } label: {
                Label(model.isListening ? "停止" : "开始录音", systemImage: model.isListening ? "stop.circle.fill" : "record.circle")
            }
            .tint(model.isListening ? .red : nil)
            .disabled(model.activity == .finishing || model.engineState != .ready)
            .help(model.engineState == .ready ? "" : "识别模型准备好后才能录音")
        }
    }
}

private struct EngineStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.engineState {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 80)
                Text("下载识别模型 \(Int(fraction * 100))%").foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("加载识别模型…").foregroundStyle(.secondary)
            }
        case .ready:
            if model.activity == .finishing {
                Text("正在转录最后几句…").foregroundStyle(.secondary)
            } else if case .listening(.replay(let url), _) = model.activity {
                Text("回放：\(url.lastPathComponent)").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label("识别模型不可用", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    // Speech RMS rarely exceeds 0.3; scale so normal speech fills most of the bar.
                    Capsule().fill(.green)
                        .frame(width: geometry.size.width * CGFloat(min(1, level * 4)))
                }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).textSelection(.enabled)
            Spacer()
            Button("关闭", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.bar)
    }
}

#Preview {
    WorkspaceView()
        .environment(AppModel())
        .frame(width: 1100, height: 700)
}
