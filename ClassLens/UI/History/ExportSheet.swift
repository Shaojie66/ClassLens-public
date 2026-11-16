import SwiftUI

/// Export a reviewed lecture to the Obsidian vault: confirm course, week and date, see the files first.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: LoadedSession

    @State private var course = ""
    @State private var week = ""
    @State private var date = Date.now
    @State private var includeAudio = true
    @State private var includeSummary = true
    @State private var customFolder: URL?

    private var location: VaultLocation? { model.defaultExportLocation(for: session) }

    private var folder: URL? {
        customFolder ?? location.map { VaultLocation(vaultRoot: $0.vaultRoot, course: course.isEmpty ? $0.course : course).classLensFolder }
    }

    private var plan: ExportPlan? {
        guard let folder, !course.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return ExportPlan(folder: folder, course: course.trimmingCharacters(in: .whitespaces), week: Int(week), lectureDate: date, includeAudio: includeAudio, includeSummary: includeSummary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出到 Obsidian").font(.title3.weight(.semibold))
            Form {
                TextField("课程", text: $course, prompt: Text("例如 SCEM"))
                TextField("周次", text: $week, prompt: Text("例如 7，可以留空"))
                DatePicker("上课日期", selection: $date, displayedComponents: .date)
                Toggle("一起导出录音（m4a）", isOn: $includeAudio)
                Toggle("生成 AI 课后总结（\(model.provider.strongModel)，约 0.05 美元）", isOn: $includeSummary)
            }
            .formStyle(.grouped)
            .disabled(isRunning)

            if let plan {
                VStack(alignment: .leading, spacing: 4) {
                    Text("将新建这些文件（不会覆盖已有文件）：").font(.callout).foregroundStyle(.secondary)
                    ForEach(plan.files, id: \.self) { file in
                        Text(file.path.replacingOccurrences(of: location?.vaultRoot.path ?? "", with: "…"))
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if plan.isRenamed {
                        Label("同名文件已经存在，改用了带编号的新名字。", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            } else if location == nil, customFolder == nil {
                Label("这节课的课件不在 Obsidian 库的“模块/<课程>/”下，没法自动确定位置。", systemImage: "questionmark.folder")
                    .font(.callout)
            }

            status
            HStack {
                Button("选择其他文件夹…") { chooseFolder() }.disabled(isRunning)
                Spacer()
                Button("关闭") { dismiss() }.disabled(isRunning)
                Button("导出") {
                    guard let plan else { return }
                    Task { await model.export(session, plan: plan) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || isRunning || isDone)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            model.exportState = .idle
            course = location?.course ?? ""
            week = model.defaultWeek(for: session).map(String.init) ?? ""
            date = session.summary.meta.createdAt
        }
    }

    private var isRunning: Bool {
        if case .running = model.exportState { true } else { false }
    }

    private var isDone: Bool {
        if case .done = model.exportState { true } else { false }
    }

    @ViewBuilder private var status: some View {
        switch model.exportState {
        case .idle:
            EmptyView()
        case .running(let step):
            HStack { ProgressView().controlSize(.small); Text(step) }
        case .done(let files, let summaryError):
            VStack(alignment: .leading, spacing: 6) {
                Label("已导出 \(files.count) 个文件", systemImage: "checkmark.circle").foregroundStyle(.green)
                if let summaryError { Label("AI 课后总结没有生成：\(summaryError)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Button("在访达中显示") { model.revealExport(files) }
                    if let transcript = files.first { Button("用 Obsidian 打开") { model.openInObsidian(transcript) } }
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择导出到哪个文件夹（会在里面建 转写/、录音/、AI总结/）"
        if panel.runModal() == .OK { customFolder = panel.url }
    }
}
