import AppKit
import SwiftUI

/// What the student can do with selected text.
enum SelectionMenuItem {
    case explain, translate, custom

    var title: String {
        switch self {
        case .explain: "解释"
        case .translate: "翻译"
        case .custom: "提问…"
        }
    }

    var symbol: String {
        switch self {
        case .explain: "sparkles"
        case .translate: "character.book.closed"
        case .custom: "questionmark.bubble"
        }
    }
}

/// The small bar that floats above a selection with 解释 / 翻译 / 提问…. One instance serves the slides and
/// the captions; it closes itself when the student clicks anywhere else.
@MainActor
final class SelectionPopover: NSObject, NSPopoverDelegate {
    static let shared = SelectionPopover()

    private let popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        return popover
    }()

    func show(relativeTo rect: NSRect, of view: NSView, onAction: @escaping (SelectionMenuItem) -> Void) {
        let content = SelectionActionsBar { [weak self] item in
            self?.popover.performClose(nil)
            onAction(item)
        }
        popover.contentViewController = FirstClickHostingController(rootView: content)
        // Above the selection: in flipped views (text views) the top edge is minY.
        popover.show(relativeTo: rect.insetBy(dx: 0, dy: -2), of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }
}

/// The popover is its own window and isn't key when it appears; by default the first click would only
/// activate it, so the student had to click 解释 twice. Its buttons take the first click instead.
private final class FirstClickHostingController: NSViewController {
    private let rootView: SelectionActionsBar

    init(rootView: SelectionActionsBar) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let host = FirstClickHostingView(rootView: rootView)
        host.sizingOptions = .intrinsicContentSize
        view = host
        preferredContentSize = host.fittingSize
    }
}

private final class FirstClickHostingView: NSHostingView<SelectionActionsBar> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SelectionActionsBar: View {
    let onAction: (SelectionMenuItem) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([SelectionMenuItem.explain, .translate, .custom], id: \.self) { item in
                Button {
                    onAction(item)
                } label: {
                    Label(item.title, systemImage: item.symbol).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
                .help(item == .explain ? "让 AI 解释选中内容（⌘E）" : "")
            }
        }
        .font(.callout)
        .padding(6)
        .fixedSize()
    }
}
