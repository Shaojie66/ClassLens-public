import AppKit
import SwiftUI

/// A caption line the student can select words in. SwiftUI's `Text` allows selection but never tells
/// the app what was selected, so this wraps a selectable AppKit label and reports the selection.
struct SelectableText: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var color: NSColor = .labelColor
    /// Called with the selected words, or nil when the selection is cleared.
    let onSelection: (String?) -> Void
    /// Called when the student picks 解释 / 翻译 / 提问… (from the floating bar or the right-click menu).
    let onAction: (SelectionMenuItem, String) -> Void
    /// Extra right-click items after the selection ones, such as "answer this line".
    var extraMenu: [(title: String, action: () -> Void)] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CaptionField {
        let field = CaptionField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.allowsEditingTextAttributes = false
        field.drawsBackground = false
        field.isBezeled = false
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.coordinator = context.coordinator
        context.coordinator.field = field
        apply(to: field)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        return field
    }

    func updateNSView(_ field: CaptionField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        apply(to: field)
    }

    /// Wraps to the width SwiftUI offers. With no usable offer (an ideal-size query) it answers a modest
    /// width, never the width of the whole line unwrapped, which would push the column wider than the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: CaptionField, context: Context) -> CGSize? {
        let offered = proposal.width ?? 0
        let width = offered.isFinite && offered > 0 ? offered : 320
        field.preferredMaxLayoutWidth = width
        let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)) ?? .zero
        return CGSize(width: width, height: ceil(size.height))
    }

    private func apply(to field: CaptionField) {
        field.font = font
        field.textColor = color
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SelectableText
        weak var field: CaptionField?
        private var lastShown: String?

        init(_ parent: SelectableText) {
            self.parent = parent
        }

        /// The window's shared field editor reports every selection change; only ours count.
        @objc func selectionChanged(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, let field, editor.delegate === field else { return }
            let selected = Self.selectedText(in: editor)
            parent.onSelection(selected)
            guard let selected else {
                lastShown = nil
                return
            }
            // A right-click selects the word under it and opens the context menu, which already has the
            // same actions; floating the bar on top of the menu would just clutter it.
            if let type = NSApp.currentEvent?.type, type == .rightMouseDown || type == .rightMouseUp {
                lastShown = selected
                return
            }
            // Show the floating bar once the mouse is up, not on every step of a drag.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak editor] in
                guard let self, let editor, NSEvent.pressedMouseButtons == 0,
                      Self.selectedText(in: editor) == selected, self.lastShown != selected else { return }
                self.lastShown = selected
                self.showBar(for: editor, text: selected)
            }
        }

        static func selectedText(in editor: NSTextView) -> String? {
            let range = editor.selectedRange()
            guard range.length > 0 else { return nil }
            let text = (editor.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        private func showBar(for editor: NSTextView, text: String) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: editor.selectedRange(), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += editor.textContainerOrigin.x
            rect.origin.y += editor.textContainerOrigin.y
            SelectionPopover.shared.show(relativeTo: rect, of: editor) { [weak self] item in
                self?.parent.onAction(item, text)
            }
        }

        func menuItems(for editor: NSTextView) -> [NSMenuItem] {
            var items: [NSMenuItem] = []
            if let text = Self.selectedText(in: editor) {
                for item in [SelectionMenuItem.explain, .translate, .custom] {
                    let title = item == .custom ? "就选中的内容提问…" : "让 AI \(item.title)选中的内容"
                    items.append(ClosureMenuItem(title: title, symbol: item.symbol, key: item == .explain ? "e" : "") { [weak self] in
                        self?.parent.onAction(item, text)
                    })
                }
            }
            if !items.isEmpty, !parent.extraMenu.isEmpty { items.append(.separator()) }
            for extra in parent.extraMenu {
                items.append(ClosureMenuItem(title: extra.title, symbol: nil, key: "", action: extra.action))
            }
            return items
        }
    }
}

/// The label behind `SelectableText`; adds ClassLens items to the field editor's right-click menu.
final class CaptionField: NSTextField, NSTextViewDelegate {
    weak var coordinator: SelectableText.Coordinator?

    /// No intrinsic width: the layout decides how wide a caption is and the text wraps to it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let coordinator else { return menu }
        let items = coordinator.menuItems(for: view)
        guard !items.isEmpty else { return menu }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.field = self
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String?, key: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) {
        fatalError("not used from nibs")
    }

    @objc private func run() {
        handler()
    }
}
