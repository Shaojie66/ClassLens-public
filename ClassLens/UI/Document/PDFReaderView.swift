import AppKit
import PDFKit
import SwiftUI

/// PDFKit's viewer with three extra items at the top of the right-click menu when text is selected.
struct PDFReaderView: NSViewRepresentable {
    let document: PDFDocument
    /// The page to show; changes made here are not reported back as the student's.
    let page: Int
    /// The student scrolled or turned to a page.
    let onUserPage: (Int) -> Void
    /// The selection changed: its text and page (1-based), or nil when cleared. Feeds ⌘E.
    var onSelection: (String?, Int) -> Void = { _, _ in }
    /// Selected text, its page (1-based) and what to do with it.
    let onAsk: (String, Int, SelectionMenuItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AskablePDFView {
        let view = AskablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = document
        view.onAsk = { context.coordinator.parent.onAsk($0, $1, $2) }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: .PDFViewSelectionChanged, object: view)
        return view
    }

    func updateNSView(_ view: AskablePDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document {
            view.document = document
        }
        if let target = document.page(at: page), view.currentPage !== target {
            context.coordinator.expectedPage = page
            view.go(to: target)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFReaderView
        /// The page the app asked for; reaching it is not the student's doing.
        var expectedPage: Int?

        init(_ parent: PDFReaderView) {
            self.parent = parent
        }

        @objc func selectionChanged(_ notification: Notification) {
            guard let view = notification.object as? AskablePDFView else { return }
            let selected = view.selectedText
            parent.onSelection(selected?.text, selected?.page ?? 1)
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let current = view.currentPage, let document = view.document else { return }
            let index = document.index(for: current)
            if let expected = expectedPage {
                // Going to a page can pass through others on the way; only the arrival ends the move.
                if index == expected { expectedPage = nil }
                return
            }
            guard index != parent.page else { return }
            // PDFKit also reports page changes during layout (opening, resizing). Only scrolling, keys and
            // clicks are the student turning the page.
            let input: Set<NSEvent.EventType> = [.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .swipe, .gesture]
            guard let type = NSApp.currentEvent?.type, input.contains(type) else { return }
            parent.onUserPage(index)
        }
    }
}

final class AskablePDFView: PDFView {
    var onAsk: ((String, Int, SelectionMenuItem) -> Void)?

    /// The selected text and its page (1-based), if any.
    var selectedText: (text: String, page: Int)? {
        guard let selection = currentSelection, let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let page = selection.pages.first.flatMap { document?.index(for: $0) }.map { $0 + 1 } ?? 1
        return (text, page)
    }

    /// After a drag that selected text, float 解释 / 翻译 / 提问… above the selection.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let (text, page) = selectedText, let selection = currentSelection, let first = selection.pages.first else { return }
        let rect = convert(selection.bounds(for: first), from: first)
        SelectionPopover.shared.show(relativeTo: rect, of: self) { [weak self] item in
            self?.onAsk?(text, page, item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let (text, page) = selectedText else {
            return menu
        }
        let items: [(String, String, SelectionMenuItem)] = [
            ("让 AI 解释这段（⌘E）", "sparkles", .explain),
            ("翻译这段", "character.book.closed", .translate),
            ("就这段提问…", "questionmark.bubble", .custom),
        ]
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.0, action: #selector(askFromMenu(_:)), keyEquivalent: "")
            menuItem.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
            menuItem.target = self
            menuItem.representedObject = AskRequest(text: text, page: page, item: item.2)
            menu.insertItem(menuItem, at: index)
        }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    @objc private func askFromMenu(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? AskRequest else { return }
        onAsk?(request.text, request.page, request.item)
    }

    private final class AskRequest: NSObject {
        let text: String
        let page: Int
        let item: SelectionMenuItem

        init(text: String, page: Int, item: SelectionMenuItem) {
            self.text = text
            self.page = page
            self.item = item
        }
    }
}
