import AppKit
import Combine
import SwiftUI

// Focus is never forced from updateNSView — AppKit raises
// NSInternalInconsistencyException for that; the subclass reports native
// activation instead.
final class CellTextView: NSTextView {
    var didBecomeFirstResponderHandler: (() -> Void)?
    var flushPendingEditsHandler: (() -> Void)?
    /// Return true from keyDown handling to consume the event before typing.
    var keyCommandHandler: ((NSEvent) -> Bool)?
    weak var undoManagerOverride: UndoManager?

    // nil, not the shared manager: AppKit's typing path registers ungrouped
    // coalescing undos, which the group-based shared manager throws on.
    override var undoManager: UndoManager? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        if keyCommandHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { didBecomeFirstResponderHandler?() }
        return accepted
    }

    // The Undo/Redo menu actions land on whoever is first responder; claim
    // them and drive the shared manager so one undo reverts one whole change.
    @objc func undo(_ sender: Any?) {
        flushPendingEditsHandler?()
        undoManagerOverride?.undo()
    }

    @objc func redo(_ sender: Any?) {
        flushPendingEditsHandler?()
        undoManagerOverride?.redo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return undoManagerOverride?.canUndo ?? false
        case #selector(redo(_:)):
            return undoManagerOverride?.canRedo ?? false
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

// Content sync is dual-path by necessity: SwiftUI sometimes skips
// updateNSView after a model change (observed after undo/redo), so the
// coordinator also subscribes to the revision publisher and pulls live
// content. Whichever path fires first applies; the other sees equal text
// and skips.
struct NSTextViewRepresentable: NSViewRepresentable {
    var content: NSAttributedString
    /// Text is re-applied only on revision bumps, so a stale render pass
    /// can't revert text the user just typed.
    var contentRevision: Int
    var revision: AnyPublisher<Int, Never>
    /// Live read from the view model — never a render-time snapshot.
    var contentProvider: () -> NSAttributedString
    var isHeader: Bool
    var scrolls: Bool = false
    var font: NSFont = NSFont.systemFont(ofSize: 13)
    var undoManager: UndoManager? = nil
    var flushPendingEdits: () -> Void = {}
    var onTextChange: (NSAttributedString) -> Void
    var onSelectionChange: (NSRange) -> Void
    var onFocus: () -> Void
    /// Grid keys (Tab/Return/Escape) reported here; true = consumed. The
    /// HTML pane leaves the default so its Tab/Return insert characters.
    var onGridKey: (NSEvent) -> Bool = { _ in false }
    /// Keyboard focus follows this flag only on false→true transitions that
    /// start inside the grid, so clicks and doc switches never yank focus.
    var isFocused: Bool = false

    /// labelColor is appearance-dynamic; text lacking .foregroundColor
    /// renders BLACK regardless of textColor — invisible in dark mode.
    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    static func background(isHeader: Bool) -> NSColor {
        isHeader ? .unemphasizedSelectedContentBackgroundColor : .controlBackgroundColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CellTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        // Undo is owned by the shared editor manager, not the text view.
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = Self.background(isHeader: isHeader)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = font
        // Typed characters must carry the model's attributes, or every
        // keystroke looks "changed" and gets replaced mid-edit.
        textView.typingAttributes = Self.baseAttributes(font: font)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 3, height: 3)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // widthTracksTextView is the wrapping switch (no
        // widthTracksLineFragmentSize in this SDK).
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(content)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = scrolls
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        wire(textView: textView, coordinator: context.coordinator)
        context.coordinator.lastAppliedRevision = contentRevision
        context.coordinator.lastFocused = isFocused
        context.coordinator.observeRevision(revision, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CellTextView else { return }
        wire(textView: textView, coordinator: context.coordinator)

        if context.coordinator.lastAppliedRevision != contentRevision {
            context.coordinator.apply(content: content, revision: contentRevision, to: textView)
        }

        // Focus bridge: follow false→true grid moves only when the keyboard
        // is already in the grid; initial creation (nil→true) must not steal
        // focus, preserving the click-to-edit contract.
        if context.coordinator.lastFocused != isFocused {
            let previous = context.coordinator.lastFocused
            context.coordinator.lastFocused = isFocused
            if isFocused, previous == false, textView.window?.firstResponder is CellTextView {
                DispatchQueue.main.async {
                    guard textView.window?.firstResponder is CellTextView,
                          textView.window?.firstResponder !== textView else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }

        textView.backgroundColor = Self.background(isHeader: isHeader)
    }

    private func wire(textView: CellTextView, coordinator: Coordinator) {
        textView.undoManagerOverride = undoManager
        // Native activation path: click -> becomeFirstResponder -> focus report.
        textView.didBecomeFirstResponderHandler = { [weak coordinator] in
            coordinator?.parent.onFocus()
        }
        textView.flushPendingEditsHandler = { [weak coordinator] in
            coordinator?.parent.flushPendingEdits()
        }
        textView.keyCommandHandler = { [weak coordinator] event in
            coordinator?.parent.onGridKey(event) ?? false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NSTextViewRepresentable
        var lastAppliedRevision: Int?
        var lastFocused: Bool?
        private var revisionCancellable: AnyCancellable?

        init(parent: NSTextViewRepresentable) {
            self.parent = parent
        }

        func observeRevision(_ publisher: AnyPublisher<Int, Never>, textView: CellTextView) {
            revisionCancellable = publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak textView] revision in
                    guard let self, let textView else { return }
                    guard self.lastAppliedRevision != revision else { return }
                    self.apply(content: self.parent.contentProvider(), revision: revision, to: textView)
                }
        }

        func apply(content: NSAttributedString, revision: Int, to textView: CellTextView) {
            lastAppliedRevision = revision
            guard !(textView.textStorage?.isEqual(to: content) ?? false) else { return }
            let savedSelection = textView.selectedRanges
            textView.textStorage?.setAttributedString(content)
            // NSSelectionArray rejects empty arrays (raises, crashes) and
            // out-of-range values, e.g. after undo empties a cell.
            var selection = savedSelection.filter { $0.rangeValue.upperBound <= content.length }
            if selection.isEmpty {
                selection = [NSValue(range: NSRange(location: content.length, length: 0))]
            }
            textView.selectedRanges = selection
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            parent.onTextChange(NSAttributedString(attributedString: storage))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onSelectionChange(textView.selectedRange())
        }
    }
}
