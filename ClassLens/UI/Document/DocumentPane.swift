import SwiftUI
import UniformTypeIdentifiers

/// Left side of the window: the slides, or a place to drop them.
struct DocumentPane: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        Group {
            if let app = model.convertingWith {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在用 \(app) 把课件转成 PDF…").foregroundStyle(.secondary)
                    Text("第一次转换时，macOS 会询问是否允许 ClassLens 控制 \(app)，请点“好”。")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document = model.document {
                VStack(spacing: 0) {
                    PDFReaderView(document: document.pdf, page: model.currentPage, onUserPage: model.userTurnedPage, onSelection: { text, page in
                        model.selectionChanged(text.map { TextSelection(text: document.repaired($0), source: .slide(page: page)) })
                    }) { text, page, item in
                        let selection = TextSelection(text: document.repaired(text), source: .slide(page: page))
                        switch item {
                        case .explain: model.ask(selection, action: .explain)
                        case .translate: model.ask(selection, action: .translate)
                        case .custom: model.pendingSelection = selection
                        }
                    }
                    Divider()
                    DocumentStatusBar(document: document)
                }
            } else {
                ContentUnavailableView {
                    Label("未打开课件", systemImage: "doc.richtext")
                } description: {
                    Text("课前打开或拖入 PPT / PDF 课件，开讲前术语表就能准备好。选中文字后右键，就能让 AI 解释、翻译或回答你的问题。")
                } actions: {
                    Button("打开课件…") { model.chooseDocument() }
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: AppModel.canOpen) else { return false }
            Task { await model.openDocument(url) }
            return true
        } isTargeted: { dropTargeted = $0 }

    }
}

private struct DocumentStatusBar: View {
    @Environment(AppModel.self) private var model
    let document: LectureDocument

    var body: some View {
        HStack(spacing: 12) {
            Text(document.name).lineLimit(1).truncationMode(.middle)
            Text("第 \(model.currentPage + 1) / \(document.pageCount) 页").monospacedDigit()
            if let slide = model.teacherSlide {
                if model.isFollowing {
                    Label("跟随老师 · 约 \(Int(slide.probability * 100))%", systemImage: "figure.wave")
                        .help("根据老师最近说的话判断他讲到了第 \(slide.page + 1) 页，偶尔会慢一页；手动翻页会暂停跟随")
                } else if model.followTeacher {
                    Button("老师在第 \(slide.page + 1) 页 · 恢复跟随", systemImage: "arrow.uturn.forward") { model.resumeFollowing() }
                        .buttonStyle(.borderless)
                } else {
                    Button("老师在第 \(slide.page + 1) 页", systemImage: "figure.wave") { model.currentPage = slide.page }
                        .buttonStyle(.borderless)
                        .help("跟随已在“选项”里关闭，点一下跳到这一页")
                }
            }
            Spacer()
            switch model.glossaryState {
            case .none:
                EmptyView()
            case .extracting:
                ProgressView().controlSize(.small)
                Text("正在从课件抽取术语…")
            case .ready(let count):
                Label("术语 \(count) 个", systemImage: "text.book.closed")
                    .help("这些术语会用来帮助识别、统一翻译用词和回答问题")
            case .failed(let message):
                Label("术语表不可用", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(message)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The student types their own question about selected slide text or caption words.
struct SelectionQuestionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: TextSelection
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("就选中的内容提问").font(.headline)
            Text(selection.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            TextField("例如：这个公式里的 s 是什么？", text: $question, axis: .vertical)
                .lineLimit(2...5)
                .onSubmit(send)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("提问", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func send() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.ask(selection, action: .ask(trimmed))
        dismiss()
    }
}
