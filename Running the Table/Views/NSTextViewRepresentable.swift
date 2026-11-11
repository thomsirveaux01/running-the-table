import AppKit
import Combine
import SwiftUI

/// Row/column edits a cell's context menu offers; the raw value rides along as
/// the menu item's tag so one action method dispatches all four.
enum CellCommand: Int {
    case addRowAbove, addRowBelow, addColumnLeft, addColumnRight
}

private let cellCommandTitles: [(CellCommand, String)] = [
    (.addRowAbove, "Add Row Above"), (.addRowBelow, "Add Row Below"),
    (.addColumnLeft, "Add Column Left"), (.addColumnRight, "Add Column Right"),
]

// Focus is never forced from updateNSView — AppKit raises
// NSInternalInconsistencyException for that; the subclass reports native
// activation instead.
final class CellTextView: NSTextView {
    var didBecomeFirstResponderHandler: (() -> Void)?
    var flushPendingEditsHandler: (() -> Void)?
    /// Non-nil only in the grid: the HTML source pane has no rows to add.
    var cellCommandHandler: ((CellCommand) -> Void)?
    /// Return true from keyDown handling to consume the event before typing.
    var keyCommandHandler: ((NSEvent) -> Bool)?
    weak var undoManagerOverride: UndoManager?
    var highlightsCurrentLine = false
    /// Drag-selection state, set only in the grid: this slot's visual
    /// rectangle, the grid's point→cell hit-test, and the selection sink.
    var gridVisualOrigin: VisualCell?
    var gridVisualSpan = 1
    var gridVisualRowSpan = 1
    var visualCellAt: ((NSPoint) -> VisualCell?)?
    var cellRangeHandler: ((VisualCellRange?) -> Void)?
    /// Overrides the watched pointer position (window-base) during a gesture;
    /// nil reads the real cursor. Test harnesses drive scripted points.
    var pointerLocationOverride: (() -> NSPoint?)?
    /// With a cell range selected, ⌘C copies the cells instead of the text;
    /// returns true when it handled the event. Nil outside the grid.
    var copyCellsHandler: (() -> Bool)?
    /// ⌘V with a table on the pasteboard makes a new table instead of dumping
    /// flat text into the cell; returns true when handled. Nil outside the grid.
    var pasteTableHandler: (() -> Bool)?
    private var isDraggingCells = false

    // nil, not the shared manager: AppKit's typing path registers ungrouped
    // coalescing undos, which the group-based shared manager throws on.
    override var undoManager: UndoManager? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        if keyCommandHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard gridVisualOrigin != nil else {
            super.mouseDown(with: event)
            return
        }
        cellRangeHandler?(nil)
        isDraggingCells = false
        // NSTextView.mouseDown pumps the whole click-drag gesture itself —
        // subclass mouseDragged/mouseUp never fire — so the pointer is watched
        // from a timer, which runs because the pump spins the runloop in
        // eventTracking mode (measured, tools/dragsel_probe).
        let watch = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollPointer()
        }
        RunLoop.current.add(watch, forMode: .eventTracking)
        RunLoop.current.add(watch, forMode: .default)
        super.mouseDown(with: event)
        // The release position must land in the selection even if the watch
        // never polled between the last move and the mouse-up.
        pollPointer()
        watch.invalidate()
        isDraggingCells = false
    }

    private func pollPointer() {
        guard let window else { return }
        let point: NSPoint
        if let scripted = pointerLocationOverride?() {
            point = scripted
        } else {
            let screen = NSEvent.mouseLocation
            point = window.convertFromScreen(NSRect(x: screen.x, y: screen.y, width: 0, height: 0)).origin
        }
        gestureMoved(toWindowPoint: point)
    }

    /// Hit-tests the pointer (window-base coordinates) and updates the range
    /// selection; the watch timer drives this, and the harness injects points.
    func gestureMoved(toWindowPoint p: NSPoint) {
        guard let origin = gridVisualOrigin, let doc = gridDocumentView,
              let hit = visualCellAt?(doc.convert(p, from: nil)) else { return }
        let inside = hit.row == origin.row && hit.column >= origin.column
            && hit.column < origin.column + gridVisualSpan
        // While the pointer stays in its own slot, text editing is NSTextView's.
        if inside && !isDraggingCells { return }
        isDraggingCells = true
        cellRangeHandler?(VisualCellRange(
            rowStart: min(origin.row, hit.row),
            rowEnd: max(origin.row + gridVisualRowSpan - 1, hit.row),
            colStart: min(origin.column, hit.column),
            colEnd: max(origin.column + gridVisualSpan - 1, hit.column)))
    }

    /// The grid's scroll view is the outermost one above the cell (each cell
    /// carries its own wrapper); its top-origin document view is the space
    /// drag hit-tests happen in.
    private var gridDocumentView: NSView? {
        var grid: NSScrollView?
        var view = superview
        while let s = view {
            if let scroll = s as? NSScrollView, scroll.documentView !== self { grid = scroll }
            view = s.superview
        }
        return grid?.documentView
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { didBecomeFirstResponderHandler?() }
        return accepted
    }

    // DIAGNOSTIC: removed to test the "multiple persistent carets" report.
    // A leftover selection keeps drawing as a gray highlight after the cell
    // gives up focus; collapse it so clicking away clears it.
    /*
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            let loc = min(selectedRange().location, (string as NSString).length)
            selectedRanges = [NSValue(range: NSRange(location: loc, length: 0))]
        }
        return accepted
    }
    */

    // IDE-style band behind the caret's line.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightsCurrentLine,
              let layoutManager, let container = textContainer,
              layoutManager.glyphRange(for: container).length > 0 else { return }
        let caret = min(selectedRange().location, (string as NSString).length)
        let lastGlyph = layoutManager.glyphRange(for: container).length - 1
        let glyph = min(layoutManager.glyphIndexForCharacter(at: caret), lastGlyph)
        var effective = NSRange()
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
        let origin = textContainerOrigin
        let band = NSRect(x: bounds.minX, y: lineRect.minY + origin.y,
                          width: bounds.width, height: lineRect.height)
        let dirty = band.intersection(rect)
        guard !dirty.isEmpty else { return }
        NSColor.quaternaryLabelColor.setFill()
        dirty.fill()
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

    // Menu ⌘C arrives here as copy: on the first responder, so a live cell
    // range takes it over before the text system can copy just this cell.
    override func copy(_ sender: Any?) {
        if copyCellsHandler?() == true { return }
        super.copy(sender)
    }

    // ⌘V likewise lands here; a copied cell range is a table, so promote it to
    // its own document rather than flattening every cell into this one.
    override func paste(_ sender: Any?) {
        if pasteTableHandler?() == true { return }
        super.paste(sender)
    }

    @objc private func performCellCommand(_ sender: NSMenuItem) {
        if let kind = CellCommand(rawValue: sender.tag) { cellCommandHandler?(kind) }
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

    // Drops AppKit's system-suggestion cluster and the Font submenu. Selectors
    // measured offscreen (tools/viewmenu); Font's identifier is nib-generated.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        // "_rvMenuItemAction" is the remote-view item Siri, Look Up, and
        // Translate are rendered through.
        let suggestions: Set<String> = ["_rvMenuItemAction", "_searchWithGoogleFromMenu:"]
        let fontPanel = NSSelectorFromString("orderFrontFontPanel:")
        // Removals leave leading and doubled dividers; a dropped item counts as
        // transparent, so dividers either side of the Font submenu collapse too.
        var previousWasSeparator = true
        var drop: [NSMenuItem] = []
        for item in menu.items {
            let action = item.action.map(NSStringFromSelector) ?? ""
            if suggestions.contains(action) || item.submenu?.items.contains(where: { $0.action == fontPanel }) == true {
                drop.append(item)
            } else if item.isSeparatorItem {
                if previousWasSeparator { drop.append(item) }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        drop.forEach { menu.removeItem($0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        insertCellCommands(in: menu)
        return menu
    }

    // Grid cells get row/column edits right after the paste group, where the
    // pruned menu already leaves a divider to close the group with.
    private func insertCellCommands(in menu: NSMenu) {
        guard cellCommandHandler != nil else { return }
        let pasteActions: Set<String> = ["cut:", "copy:", "paste:", "pasteAsPlainText:"]
        let at = (menu.items.lastIndex { pasteActions.contains($0.action.map(NSStringFromSelector) ?? "") } ?? -1) + 1
        for (offset, entry) in cellCommandTitles.enumerated() {
            let item = NSMenuItem(title: entry.1, action: #selector(performCellCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = entry.0.rawValue
            menu.insertItem(item, at: at + offset)
        }
        if at + cellCommandTitles.count < menu.items.count,
           !menu.items[at + cellCommandTitles.count].isSeparatorItem {
            menu.insertItem(.separator(), at: at + cellCommandTitles.count)
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
    var font: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
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
    /// Source-pane decorations (HTML pane only): syntax colors, gutter, caret band.
    var highlightsSyntax = false
    var showsLineNumbers = false
    var highlightsCurrentLine = false
    /// Row/column commands for the context menu; nil outside the grid.
    var cellCommands: ((CellCommand) -> Void)? = nil
    /// Drag-selection support, set only on grid cells: this slot's visual
    /// rectangle, and the grid's point→cell hit-test and selection sink.
    var gridVisualOrigin: VisualCell?
    var gridVisualSpan = 1
    var gridVisualRowSpan = 1
    var visualCellAt: ((NSPoint) -> VisualCell?)?
    var cellRangeHandler: ((VisualCellRange?) -> Void)?
    /// With a cell range selected, ⌘C copies the cells; true = handled.
    var copyCells: (() -> Bool)?
    /// ⌘V with a table on the pasteboard makes a new table; true = handled.
    var pasteTable: (() -> Bool)?

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
        // Explicit TextKit 1 stack at creation: touching .layoutManager on a
        // default (TextKit 2) view switches layout systems mid-setup and the
        // layer-backed view then renders blank. Temporary attributes need TK1.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = CellTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), textContainer: container)
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
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 3, height: 3)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // widthTracksTextView is the wrapping switch (no
        // widthTracksLineFragmentSize in this SDK).
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.applyingProgrammaticContent = true
        textView.textStorage?.setAttributedString(content)
        context.coordinator.applyingProgrammaticContent = false
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = scrolls
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        if showsLineNumbers {
            let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
            ruler.ruleThickness = 40
            // AppKit's rule-edge line escapes the ruler and paints a hairline over the pane header.
            ruler.clipsToBounds = true
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        wire(textView: textView, coordinator: context.coordinator)
        context.coordinator.lastAppliedRevision = contentRevision
        context.coordinator.lastFocused = isFocused
        context.coordinator.observeRevision(revision, textView: textView)
        context.coordinator.refreshDecorations(textView)
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
        context.coordinator.refreshDecorations(textView)
    }

    private func wire(textView: CellTextView, coordinator: Coordinator) {
        textView.undoManagerOverride = undoManager
        textView.highlightsCurrentLine = highlightsCurrentLine
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
        // Must go nil outside the grid, or the HTML pane would offer dead row commands.
        if cellCommands == nil {
            textView.cellCommandHandler = nil
        } else {
            textView.cellCommandHandler = { [weak coordinator] command in
                guard let commands = coordinator?.parent.cellCommands else { return }
                commands(command)
            }
        }
        textView.gridVisualOrigin = gridVisualOrigin
        textView.gridVisualSpan = gridVisualSpan
        textView.gridVisualRowSpan = gridVisualRowSpan
        textView.visualCellAt = visualCellAt
        textView.cellRangeHandler = cellRangeHandler
        textView.copyCellsHandler = copyCells
        textView.pasteTableHandler = pasteTable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NSTextViewRepresentable
        var lastAppliedRevision: Int?
        var lastFocused: Bool?
        private var revisionCancellable: AnyCancellable?
        // AppKit echoes programmatic text/selection swaps back as delegate
        // callbacks; publishing those would mutate the model mid-view-update.
        var applyingProgrammaticContent = false

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
            applyingProgrammaticContent = true
            textView.textStorage?.setAttributedString(content)
            // NSSelectionArray rejects empty arrays (raises, crashes) and
            // out-of-range values, e.g. after undo empties a cell.
            var selection = savedSelection.filter { $0.rangeValue.upperBound <= content.length }
            if selection.isEmpty {
                selection = [NSValue(range: NSRange(location: content.length, length: 0))]
            }
            textView.selectedRanges = selection
            applyingProgrammaticContent = false
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingProgrammaticContent else { return }
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            parent.onTextChange(NSAttributedString(attributedString: storage))
            refreshDecorations(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingProgrammaticContent else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.onSelectionChange(textView.selectedRange())
            if parent.highlightsCurrentLine { textView.needsDisplay = true }
        }

        // Derived decoration only: layout-manager temporary attributes never
        // reach the text storage, so the model, undo, and equality-skip sync
        // stay untouched.
        func refreshDecorations(_ textView: NSTextView) {
            if parent.highlightsSyntax, let layoutManager = textView.layoutManager {
                let ns = textView.string as NSString
                let full = NSRange(location: 0, length: ns.length)
                layoutManager.setTemporaryAttributes([:], forCharacterRange: full)
                for (range, color) in HTMLHighlighter.colorRuns(in: textView.string) {
                    layoutManager.setTemporaryAttributes([.foregroundColor: color], forCharacterRange: range)
                }
            }
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            if parent.highlightsSyntax || parent.highlightsCurrentLine { textView.needsDisplay = true }
        }
    }
}

// Line-number gutter for the HTML source pane.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.textView = textView
        clientView = textView
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func scrollChanged() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // AppKit hands this method an unclipped, sometimes infinite rect (measured:
        // ±9e307), not the 40pt strip — filling it paints over the text. Clip it.
        NSColor.textBackgroundColor.setFill()
        rect.intersection(bounds).fill()
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphRange.length > 0 else { return }

        let ns = textView.string as NSString
        let charStart = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
        var lineNumber = 1 + newlines(in: ns.substring(to: min(charStart, ns.length)))
        let inset = textView.textContainerInset
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont,
                                                    .foregroundColor: NSColor.tertiaryLabelColor]

        var index = glyphRange.location
        while index < NSMaxRange(glyphRange) {
            var effective = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            let charRange = layoutManager.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
            // Wrapped fragments repeat their line, so only label fragments that
            // begin right after a hard break.
            let startsLine = charRange.location == 0 || ns.character(at: charRange.location - 1) == 10
            if startsLine {
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - 6 - size.width,
                                       y: lineRect.minY + inset.height - visible.minY
                                         + (lineRect.height - size.height) / 2),
                           withAttributes: attrs)
            }
            lineNumber += newlines(in: ns.substring(with: charRange))
            index = NSMaxRange(effective)
        }
    }

    /// One line per "\n" — not `isNewline`, which would double-count CRLF files.
    private func newlines(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
    }
}
