import AppKit
import SwiftUI

/// Row/column edits a cell's context menu offers; the raw value rides along as
/// the menu item's tag so one action method dispatches them all.
enum CellCommand: Int {
    case addRowAbove, addRowBelow, addColumnLeft, addColumnRight,
        duplicateRow, duplicateColumn
}

private let cellCommandTitles: [(CellCommand, String)] = [
    (.addRowAbove, "Add Row Above"), (.addRowBelow, "Add Row Below"),
    (.addColumnLeft, "Add Column Left"), (.addColumnRight, "Add Column Right"),
    (.duplicateRow, "Duplicate Row"), (.duplicateColumn, "Duplicate Column"),
]

// Drops AppKit's system items from a text view's context menu: the
// suggestion cluster (Siri/Look Up/Translate), the Font submenu, AutoFill, and
// Services. Selectors measured offscreen (tools/viewmenu); Font's identifier
// is nib-generated. Called from menu(for:) and again from the display-cycle
// hooks below, because AppKit injects AutoFill/Services after menu(for:)
// returns.
func pruneSystemItems(from menu: NSMenu) {
    // "_rvMenuItemAction" is the remote-view item Siri, Look Up, and
    // Translate are rendered through.
    let suggestions: Set<String> = ["_rvMenuItemAction", "_searchWithGoogleFromMenu:"]
    let fontPanel = NSSelectorFromString("orderFrontFontPanel:")
    let servicesAction = NSSelectorFromString("orderFrontServicesMenu:")
    // Removals leave leading and doubled dividers; a dropped item counts as
    // transparent, so dividers either side of the Font submenu collapse too.
    var previousWasSeparator = true
    var drop: [NSMenuItem] = []
    for item in menu.items {
        let action = item.action.map(NSStringFromSelector) ?? ""
        // Services: matched by the services-menu identity (its submenu IS
        // NSApp.servicesMenu), its action, or its title. Guard the nil case:
        // with no services menu, `submenu === nil` would match every item
        // that has no submenu (Cut, Copy, …).
        let isServices = (NSApp.servicesMenu != nil && item.submenu === NSApp.servicesMenu)
            || item.action == servicesAction
            || item.title == "Services"
        // AutoFill has no stable public selector, so it is matched by title.
        let isAutoFill = item.title.lowercased() == "autofill"
        if suggestions.contains(action) || isServices || isAutoFill
            || item.submenu?.items.contains(where: { $0.action == fontPanel }) == true {
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
}

// Focus is never forced from updateNSView — AppKit raises
// NSInternalInconsistencyException for that; the subclass reports native
// activation instead.
final class CellTextView: NSTextView, NSMenuDelegate {
    var didBecomeFirstResponderHandler: (() -> Void)?
    var flushPendingEditsHandler: (() -> Void)?
    /// Non-nil only in the grid: the HTML source pane has no rows to add.
    var cellCommandHandler: ((CellCommand) -> Void)?
    /// Greys out a context-menu command the current cell can't run (duplicate
    /// on a merge-touched row/column); nil leaves every command enabled.
    var cellCommandValidator: ((CellCommand) -> Bool)?
    /// Return true from keyDown handling to consume the event before typing.
    var keyCommandHandler: ((NSEvent) -> Bool)?
    weak var undoManagerOverride: UndoManager?
    var highlightsCurrentLine = false
    /// Set only in the grid: the model cell the shared editor currently
    /// represents (handlers read it at fire time, so a re-point across a
    /// table switch keeps reporting the right cell).
    var modelCell: GridCell?
    var modelStartCol = 0
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
    /// Colspan context-menu support, set only in the grid: read the cell's
    /// current span (for the checkmark) and set a new one.
    var colspanCurrent: (() -> Int)?
    var colspanSet: ((Int) -> Void)?
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

    /// The HTML pane's line-number ruler claims the clip's left edge through a
    /// negative bounds origin (measured: {-40, 0} at rest); the width pins must
    /// leave that strip for the ruler instead of zeroing it.
    var rulerInset: CGFloat {
        guard let scroll = enclosingScrollView, scroll.rulersVisible,
              let ruler = scroll.verticalRulerView else { return 0 }
        return ruler.ruleThickness
    }

    /// True when this text view is its scroll view's document view (the HTML
    /// pane and the old per-cell wrappers). Pooled grid cells live inside a
    /// shared document view; pinning them to the grid's clip width would
    /// clamp every cell to the viewport.
    var pinsWidthToClip: Bool {
        guard let scroll = enclosingScrollView else { return false }
        return scroll.documentView === self
    }

    /// Layout width: the clip's bounds when scrolled, else our bounds, minus
    /// the horizontal inset and the ruler strip.
    var visibleLayoutWidth: CGFloat {
        let base = pinsWidthToClip ? (enclosingScrollView?.contentView.bounds.width ?? bounds.width) : bounds.width
        return max(base - 2 * textContainerInset.width - rulerInset, 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        // Inside a grid cell the editor IS the cell's paint surface (border
        // and background), so it fills the slot: TextKit's shrink-to-text
        // height would clip the cell's paint to the text, and the old
        // per-cell scroll view's tiling is gone to re-expand it.
        if let slot = superview as? GridCellClipView, slot.bounds.width > 0, slot.bounds.height > 0 {
            size = slot.bounds.size
        }
        // No horizontal scrolling: the document view's width IS the clip's
        // minus the ruler strip. On the user's Sequoia build the frame comes
        // out wider (center shifts right, right-align lands off-screen), so
        // pin it, not just the container. Grid cells keep their slot width.
        if pinsWidthToClip, let clip = enclosingScrollView?.contentView, clip.bounds.width > 0 {
            let target = clip.bounds.width - rulerInset
            if abs(size.width - target) > 0.5 { size.width = target }
        }
        super.setFrameSize(size)
        syncContainerWidth()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        var origin = newOrigin
        // No horizontal scrolling: the document view sits at the clip's left
        // edge. On Sequoia the origin drifts negative and every alignment
        // hangs off the left of the cell.
        if enclosingScrollView != nil, origin.x < -0.5 {
            origin.x = 0
        }
        super.setFrameOrigin(origin)
    }

    /// Pins the container to the visible width and the clip's x-offset to the
    /// ruler strip (zero without one); a container size change invalidates the
    /// layout automatically.
    func syncContainerWidth() {
        // Grid cells track their own frame via widthTracksTextView; the clip
        // pin exists for the HTML pane only.
        guard pinsWidthToClip, let container = textContainer else { return }
        // The ruler strip is a negative clip x-offset (HTML pane); without a
        // ruler the document must start at the clip's left edge (Sequoia
        // drifts it otherwise and every alignment shifts left).
        if let clip = enclosingScrollView?.contentView {
            let expectedX = -rulerInset
            if abs(clip.bounds.origin.x - expectedX) > 0.5 {
                clip.bounds.origin.x = expectedX
            }
        }
        let target = visibleLayoutWidth
        guard abs(container.size.width - target) > 0.5 else { return }
        container.size = NSSize(width: target, height: container.size.height)
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

    @objc private func performColspan(_ sender: NSMenuItem) {
        colspanSet?(sender.tag)
    }

    /// The Colspan submenu for the context menu, mirroring Format ▸ Colspan:
    /// items 1–6 with a checkmark on the cell's current span.
    func buildColspanMenu() -> NSMenu {
        let menu = NSMenu(title: "Colspan")
        let current = colspanCurrent?() ?? 1
        for span in TableCell.minColspan...TableCell.maxColspan {
            let item = NSMenuItem(title: "\(span)", action: #selector(performColspan(_:)), keyEquivalent: "")
            item.target = self
            item.tag = span
            item.state = (span == current) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return undoManagerOverride?.canUndo ?? false
        case #selector(redo(_:)):
            return undoManagerOverride?.canRedo ?? false
        case #selector(performCellCommand(_:)):
            // The tag carries the CellCommand; the validator greys out what the
            // current cell can't run (e.g. duplicate on a merge-touched row).
            if let kind = CellCommand(rawValue: menuItem.tag) {
                return cellCommandValidator?(kind) ?? true
            }
            return false
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        // AutoFill and Services are "contextual menu plug-in" items AppKit
        // appends during display, after every delegate hook — so they can't be
        // pruned, only opted out of. This flag (the mechanism Firefox and
        // Chromium use) stops the append at the source.
        menu.allowsContextMenuPlugIns = false
        pruneSystemItems(from: menu)
        insertCellCommands(in: menu)
        // Belt and braces: re-prune from the delegate right before the menu is
        // drawn, in case any system item slips past the flag.
        menu.delegate = self
        return menu
    }

    // Last-chance prune right before the menu is drawn, catching any system
    // item (Font submenu, suggestion cluster) that survives the flag.
    func menuWillOpen(_ menu: NSMenu) {
        pruneSystemItems(from: menu)
    }

    // Grid cells get row/column edits and the Colspan submenu right after the
    // paste group, where the pruned menu already leaves a divider to close the
    // group with.
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
        // Colspan rides with the cell-structure commands; colspanSet is nil in
        // the HTML pane, so it appears only in the grid.
        var count = cellCommandTitles.count
        if colspanSet != nil {
            let item = NSMenuItem(title: "Colspan", action: nil, keyEquivalent: "")
            item.submenu = buildColspanMenu()
            menu.insertItem(item, at: at + count)
            count += 1
        }
        if at + count < menu.items.count,
           !menu.items[at + count].isSeparatorItem {
            menu.insertItem(.separator(), at: at + count)
        }
    }
}

// Content sync is direct: the hosting body reads the model properties the
// text depends on, so @Observable re-fires updateNSView on every change —
// undo/redo included (htmlpane_probe guards that contract).
struct NSTextViewRepresentable: NSViewRepresentable {
    var content: NSAttributedString
    /// Render key: the pane's body reads the model's revision, so any bump
    /// re-fires updateNSView; apply()'s equality check protects live typing.
    var contentRevision: Int
    var isHeader: Bool
    /// The cell's alignment; the macOS 27 SDK has no NSTextView.textAlignment,
    /// so it is rendered as a paragraph style written into the storage.
    var textAlignment: NSTextAlignment = .left
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
    /// Greys out a context-menu command the cell can't run; nil = all enabled.
    var cellCommandValidator: ((CellCommand) -> Bool)? = nil
    /// With a cell range selected, ⌘C copies the cells; true = handled.
    var copyCells: (() -> Bool)?
    /// ⌘V with a table on the pasteboard makes a new table; true = handled.
    var pasteTable: (() -> Bool)?
    /// Colspan context-menu support, set only in the grid: read the cell's
    /// current span (for the checkmark) and set a new one on the cell.
    var colspanCurrent: (() -> Int)?
    var colspanSet: ((Int) -> Void)?

    /// labelColor is appearance-dynamic; text lacking .foregroundColor
    /// renders BLACK regardless of textColor — invisible in dark mode.
    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    /// Header cells get a distinct system background so the header row stays
    /// visually separate from the body; body cells fall back to the grid's
    /// controlBackgroundColor.
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
        // Header cells keep a distinct system background so the header row
        // stays visually separate from the body; body cells blend with the
        // grid's controlBackgroundColor. `updateNSView` re-applies it only
        // when the value actually changes.
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
        context.coordinator.applyAlignment(to: textView)
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
        context.coordinator.lastFocused = isFocused
        context.coordinator.refreshDecorations(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CellTextView else { return }
        wire(textView: textView, coordinator: context.coordinator)
        // @Observable re-fires this on every model change, so the pane
        // applies directly; apply() skips the write when the text is equal.
        let tPane = RTSwitchTrace.now  // TEMP
        context.coordinator.apply(content: content, to: textView)
        RTSwitchTrace.log("pane apply dt=\(String(format: "%.1f", RTSwitchTrace.now - tPane))ms syn=\(highlightsSyntax ? 1 : 0)")  // TEMP
        context.coordinator.applyAlignmentIfNeeded(to: textView)

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

        // Header cells keep a distinct system background so the header row
        // stays visually separate from the body; body cells blend with the
        // grid's controlBackgroundColor. Only write when it actually changes.
        if !textView.backgroundColor.isEqual(Self.background(isHeader: isHeader)) {
            textView.backgroundColor = Self.background(isHeader: isHeader)
        }
        context.coordinator.scheduleDecorations(textView)
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
            textView.cellCommandValidator = nil
        } else {
            textView.cellCommandHandler = { [weak coordinator] command in
                guard let commands = coordinator?.parent.cellCommands else { return }
                commands(command)
            }
            textView.cellCommandValidator = { [weak coordinator] command in
                coordinator?.parent.cellCommandValidator?(command) ?? true
            }
        }
        textView.copyCellsHandler = copyCells
        textView.pasteTableHandler = pasteTable
        textView.colspanCurrent = colspanCurrent
        textView.colspanSet = colspanSet
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NSTextViewRepresentable
        var lastFocused: Bool?
        var lastAppliedAlignment: NSTextAlignment?
        // The regex pass reruns on every pane update, but table switches feed
        // the identical string back through; caching by text keeps revisits
        // free. Two slots, least-recently-used: toggling between two tables
        // misses a single-slot cache every time. (Colors are dynamic NSColors,
        // so the cache survives appearance changes.)
        private var cachedRuns: [(text: String, runs: [(NSRange, NSColor)])] = []
        // AppKit echoes programmatic text/selection swaps back as delegate
        // callbacks; publishing those would mutate the model mid-view-update.
        var applyingProgrammaticContent = false
        // Decoration (syntax runs + ruler) is purely visual: SwiftUI re-fires
        // updateNSView several times per switch, and each synchronous pass
        // blocked the click turn. One coalesced pass on the next turn instead.
        private var decorationsScheduled = false

        init(parent: NSTextViewRepresentable) {
            self.parent = parent
        }

        func apply(content: NSAttributedString, to textView: CellTextView) {
            // Plain-string equality is a sufficient skip: the model's content
            // is style-free and the view layer only ever adds paragraph style,
            // which the alignment pass re-applies on its own. The previous
            // attributed copy-and-compare cost a full storage copy per pass.
            let current = textView.textStorage ?? NSAttributedString()
            if current.length == content.length, current.string == content.string {
                applyAlignmentIfNeeded(to: textView)
                return
            }
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
            // The swap reset the stored style; re-apply the alignment. A
            // left-aligned cell needs no write — style-free content already
            // renders left (natural) for LTR text — so skip the full-range
            // paragraph-style pass, the biggest per-cell cost in the swap.
            if parent.textAlignment == .left {
                lastAppliedAlignment = .left
            } else {
                applyAlignment(to: textView)
            }
        }

        /// Writes the alignment into the storage (render + the source a
        /// selection re-sync reads) and typingAttributes (typed text before a
        /// re-sync fires).
        func applyAlignment(to textView: CellTextView) {
            lastAppliedAlignment = parent.textAlignment
            // Re-pin the layout width where alignment is (re)applied, so a
            // stale container can't misplace the render.
            textView.syncContainerWidth()
            guard let storage = textView.textStorage else { return }
            let style = NSMutableParagraphStyle()
            style.alignment = parent.textAlignment
            if storage.length > 0 {
                // addAttribute, not setAttributes: the latter replaces the whole
                // attribute dict and would wipe .foregroundColor (labelColor),
                // turning the text black in dark mode.
                storage.addAttribute(.paragraphStyle, value: style,
                                     range: NSRange(location: 0, length: storage.length))
            }
            var ta = textView.typingAttributes
            ta[.paragraphStyle] = style
            textView.typingAttributes = ta
        }

        /// Re-applies the alignment only when it changed since the last write.
        func applyAlignmentIfNeeded(to textView: CellTextView) {
            guard parent.textAlignment != lastAppliedAlignment else { return }
            applyAlignment(to: textView)
        }

        /// A copy without .paragraphStyle, so equality checks ignore the
        /// view-layer alignment (the model's content is style-free).
        static func strippingParagraphStyle(_ s: NSAttributedString) -> NSAttributedString {
            guard s.length > 0 else { return s }
            let copy = NSMutableAttributedString(attributedString: s)
            copy.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: s.length))
            return copy
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingProgrammaticContent else { return }
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            // Keep the model's content style-free; alignment lives in
            // cell.alignment, not in the content's paragraph style.
            parent.onTextChange(Self.strippingParagraphStyle(NSAttributedString(attributedString: storage)))
            refreshDecorations(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingProgrammaticContent else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.onSelectionChange(textView.selectedRange())
            if parent.highlightsCurrentLine { textView.needsDisplay = true }
        }

        // Collapse the leftover selection when editing ends so it stops
        // drawing gray; doing it in resignFirstResponder left stuck carets.
        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let loc = min(textView.selectedRange().location, (textView.string as NSString).length)
            // Guard the echo: this programmatic swap fires selectionDidChange,
            // and publishing it mid-view-update is the "publishing from within
            // view updates" fault.
            applyingProgrammaticContent = true
            textView.selectedRanges = [NSValue(range: NSRange(location: loc, length: 0))]
            applyingProgrammaticContent = false
            // The guard swallows the echo that used to sync the model, so
            // report the collapse explicitly, off the update pass.
            DispatchQueue.main.async { [parent] in
                parent.onSelectionChange(NSRange(location: loc, length: 0))
            }
        }

        // Derived decoration only: layout-manager temporary attributes never
        // reach the text storage, so the model, undo, and equality-skip sync
        // stay untouched.
        func refreshDecorations(_ textView: NSTextView) {
            let tDec = RTSwitchTrace.now  // TEMP
            defer { RTSwitchTrace.log("decor dt=\(String(format: "%.1f", RTSwitchTrace.now - tDec))ms syntax=\(parent.highlightsSyntax ? 1 : 0)") }  // TEMP
            if parent.highlightsSyntax, let layoutManager = textView.layoutManager {
                let ns = textView.string as NSString
                let full = NSRange(location: 0, length: ns.length)
                layoutManager.setTemporaryAttributes([:], forCharacterRange: full)
                let text = textView.string
                let runs: [(NSRange, NSColor)]
                if let hit = cachedRuns.firstIndex(where: { $0.text == text }) {
                    runs = cachedRuns[hit].runs
                    if hit != 0 { cachedRuns.swapAt(0, hit) }
                } else {
                    runs = HTMLHighlighter.colorRuns(in: text)
                    cachedRuns.insert((text, runs), at: 0)
                    if cachedRuns.count > 2 { cachedRuns.removeLast() }
                }
                for (range, color) in runs {
                    layoutManager.setTemporaryAttributes([.foregroundColor: color], forCharacterRange: range)
                }
            }
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            if parent.highlightsSyntax || parent.highlightsCurrentLine { textView.needsDisplay = true }
        }

        /// Next-turn, coalesced variant of refreshDecorations for the
        /// SwiftUI update path (see decorationsScheduled).
        func scheduleDecorations(_ textView: NSTextView) {
            guard !decorationsScheduled else { return }
            decorationsScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.decorationsScheduled = false
                self.refreshDecorations(textView)
            }
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
