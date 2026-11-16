import SwiftUI

@main
struct ClassLensApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        delegate.onLaunch = { await model.handleLaunchOptions() }
    }

    var body: some Scene {
        WindowGroup("ClassLens") {
            WorkspaceView()
                .environment(model)
                // Sidebar (200) + slides (420) + captions (320) + dividers must fit the narrowest window.
                .frame(minWidth: 1100, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
        .commands {
            // ⌘E is "Use Selection for Find" by default; ClassLens has no find, so the text-editing group is
            // replaced and ⌘E means one thing: ask the AI about what is selected.
            CommandGroup(replacing: .textEditing) {
                Button("让 AI 解释选中内容") { model.explainActiveSelection() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.activeSelection == nil)
                Button("就选中内容提问…") { model.pendingSelection = model.activeSelection }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.activeSelection == nil)
            }
            CommandGroup(after: .newItem) {
                Button("打开课件…") { model.chooseDocument() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("回放录音文件…") { model.chooseReplayFile() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.activity != .idle)
            }
        }

        Window("字幕浮窗", id: SubtitleOverlay.windowID) {
            SubtitleOverlay()
                .environment(model)
                .frame(minWidth: 420, minHeight: 100)
        }
        .windowLevel(.floating)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 140)
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect
            return WindowPlacement(CGPoint(x: screen.midX - 380, y: screen.maxY - 180))
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
