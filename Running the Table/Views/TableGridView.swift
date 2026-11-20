import AppKit
import SwiftUI

/// The merged-cell grid as one drawn view: backgrounds, borders, and text are painted
/// straight from the model in one draw pass, and a single shared CellTextView materializes
/// over the focused cell for editing, so a table switch repaints one view instead of
/// typesetting every cell. The document view occupies SwiftUI's padded-container space.
struct TableGridView: NSViewRepresentable {
    var viewModel: TableViewModel

    func makeCoordinator() -> GridCoordinator { GridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let doc = GridDocumentView()
        doc.coordinator = context.coordinator
        scrollView.documentView = doc
        context.coordinator.documentView = doc
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scrollView.documentView as? GridDocumentView)?.sync()
    }
}

/// Drag state for one axis, kept out of the view model so gesture updates
/// never churn autosave or the undo stack.
final class GridDragState {
    var dragged: Int?
    var target: Int?
    var translation: CGFloat = 0
    // The moved row/column's new index; its real cells stay hidden while the
    // floating copy springs into the slot.
    var settleSlot: Int?

    func reset() {
        dragged = nil
        target = nil
        translation = 0
    }
}

@MainActor
final class GridCoordinator: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    var parent: TableGridView?
    weak var documentView: GridDocumentView?

    var rowDrag = GridDragState()
    var columnDrag = GridDragState()

    var rowStrips: [Int: RowMoveHandleView] = [:]
    var columnStrips: [Int: ColumnMoveHandleView] = [:]
    var rowResizeHandles: [Int: GridResizeHandleView] = [:]
    var columnResizeHandles: [Int: GridResizeHandleView] = [:]
    var captionField: NSTextField?
    var selectionBorder: SelectionBorderView?
    var rowGapHighlight: GapHighlightView?
    var columnGapHighlight: GapHighlightView?
    var rowFloating: DragFloatingView?
    var columnFloating: DragFloatingView?

    // AppKit echoes programmatic text/selection swaps back as delegate
    // callbacks; publishing those would mutate the model mid-view-update.
    var applyingProgrammaticContent = false

    // What the shared editor already shows, so re-syncs skip the content
    // write when the focused cell has not actually changed.
    var lastAppliedCell: GridCell?
    var lastAppliedRevision: Int?
    var lastAppliedAlignment: NSTextAlignment?

    var viewModel: TableViewModel { parent!.viewModel }

    // MARK: - Editor content / alignment

    /// Writes the focused cell's content into the shared editor when the cell or revision
    /// moved. `caret` parks the insertion point; otherwise the live selection survives.
    @discardableResult
    func apply(content: NSAttributedString, revision: Int, to textView: CellTextView,
               alignment: NSTextAlignment, caret: NSRange? = nil) -> Bool {
        guard textView.modelCell != nil else { return false }
        if lastAppliedCell == textView.modelCell, lastAppliedRevision == revision {
            let restyled = applyAlignmentIfNeeded(to: textView, alignment: alignment)
            if let caret { textView.setSelectedRange(caret) }
            return restyled
        }
        lastAppliedCell = textView.modelCell
        lastAppliedRevision = revision
        // The storage carries the view-layer paragraph style but the model's content
        // is style-free, so compare stripped to avoid a swap (and IME reset) per bump.
        let current = textView.textStorage ?? NSAttributedString()
        if NSTextViewRepresentable.Coordinator.strippingParagraphStyle(current).isEqual(to: content) {
            applyAlignmentIfNeeded(to: textView, alignment: alignment)
            if let caret { textView.setSelectedRange(caret) }
            return false
        }
        let savedSelection = textView.selectedRanges
        applyingProgrammaticContent = true
        textView.textStorage?.setAttributedString(content)
        if let caret {
            // NSIntersectionRange drops a zero-length caret sitting exactly
            // at maxRange, so clamp the caret by hand.
            let loc = min(max(caret.location, 0), content.length)
            let len = max(min(caret.length, content.length - loc), 0)
            textView.selectedRanges = [NSValue(range: NSRange(location: loc, length: len))]
        } else if textView.window?.firstResponder === textView {
            // NSSelectionArray rejects empty arrays (raises, crashes) and
            // out-of-range values, e.g. after undo empties a cell.
            var selection = savedSelection.filter { $0.rangeValue.upperBound <= content.length }
            if selection.isEmpty {
                selection = [NSValue(range: NSRange(location: content.length, length: 0))]
            }
            textView.selectedRanges = selection
        }
        applyingProgrammaticContent = false
        // A left-aligned cell needs no write — style-free content renders left for
        // LTR — so skip the full-range paragraph-style pass, the swap's biggest cost.
        if alignment == .left {
            lastAppliedAlignment = .left
        } else {
            applyAlignment(to: textView, alignment: alignment)
        }
        return true
    }

    func applyAlignment(to textView: CellTextView, alignment: NSTextAlignment) {
        lastAppliedAlignment = alignment
        guard let storage = textView.textStorage else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        if storage.length > 0 {
            // addAttribute, not setAttributes: the latter replaces the whole
            // attribute dict and would wipe .foregroundColor, blacking the text.
            storage.addAttribute(.paragraphStyle, value: style,
                                 range: NSRange(location: 0, length: storage.length))
        }
        var ta = textView.typingAttributes
        ta[.paragraphStyle] = style
        textView.typingAttributes = ta
    }

    @discardableResult
    func applyAlignmentIfNeeded(to textView: CellTextView, alignment: NSTextAlignment) -> Bool {
        guard lastAppliedAlignment != alignment else { return false }
        applyAlignment(to: textView, alignment: alignment)
        return true
    }

    // MARK: - NSTextViewDelegate (the one shared editor)

    func textDidChange(_ notification: Notification) {
        guard !applyingProgrammaticContent else { return }
        guard let textView = notification.object as? CellTextView,
              let cell = textView.modelCell,
              let storage = textView.textStorage else { return }
        // Keep the model's content style-free; alignment lives in
        // cell.alignment, not in the content's paragraph style.
        viewModel.updateCellContent(row: cell.row, col: cell.column,
                                    NSTextViewRepresentable.Coordinator.strippingParagraphStyle(NSAttributedString(attributedString: storage)))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProgrammaticContent else { return }
        guard let textView = notification.object as? NSTextView,
              let cell = (textView as? CellTextView)?.modelCell else { return }
        viewModel.updateCellSelection(row: cell.row, col: cell.column, textView.selectedRange())
    }

    // Collapse the leftover selection when editing ends so it stops
    // drawing gray; doing it in resignFirstResponder left stuck carets.
    func textDidEndEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let cell = (textView as? CellTextView)?.modelCell else { return }
        let loc = min(textView.selectedRange().location, (textView.string as NSString).length)
        // Guard the echo: this programmatic swap fires selectionDidChange, and
        // publishing it mid-view-update is the "publishing within view updates" fault.
        applyingProgrammaticContent = true
        textView.selectedRanges = [NSValue(range: NSRange(location: loc, length: 0))]
        applyingProgrammaticContent = false
        // The guard swallows the echo that used to sync the model, so
        // report the collapse explicitly, off the update pass.
        let viewModel = self.viewModel
        DispatchQueue.main.async {
            viewModel.updateCellSelection(row: cell.row, col: cell.column, NSRange(location: loc, length: 0))
            // The editor losing first responder for any reason (a click outside
            // the grid) ends the edit; never leave a stale caret mode behind.
            viewModel.cellMode = .selected
        }
    }
}

/// The shared editor's clip container: a plain layer-backed view pinning the editor to
/// the focused cell's slot and clipping overflow; the wheel rides the responder chain.
final class GridCellClipView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Setting a frame doesn't imply needsLayout; without this the editor
        // would keep its old size until something else dirties the layout.
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        // The editor always fills the slot; text taller than the slot is
        // clipped, which is the cell's whole scrolling story now.
        subviews.first?.frame = bounds
    }
}

/// One cell rendered as its own layer-backed view, so a move-drag can animate
/// its frame with `animator()` instead of teleporting the shared draw pass.
/// Text is painted through the document view's shared TextKit stack so drawn
/// and edited cells keep landing identically.
final class GridCellView: NSView {
    override var isFlipped: Bool { true }
    weak var documentView: GridDocumentView?

    var content: NSAttributedString = NSAttributedString() {
        didSet { if content != oldValue { needsDisplay = true } }
    }
    var alignment: NSTextAlignment = .left {
        didSet { if alignment != oldValue { needsDisplay = true } }
    }
    var isHeader = false {
        didSet { if isHeader != oldValue { needsDisplay = true } }
    }
    // The editor paints the focused cell's text; drawing it here too would
    // double-render (and force layout while typing).
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }
    // While a drag range is up, the range border is the only selector.
    var isRangeActive = false {
        didSet { if isRangeActive != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        NSTextViewRepresentable.background(isHeader: isHeader).setFill()
        rect.fill()
        if !isFocused {
            documentView?.drawCellText(content, alignment: alignment, in: rect)
        }
        let showRing = isFocused && !isRangeActive
        let borderW: CGFloat = showRing ? 2 : 1
        (showRing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let half = borderW / 2
        let path = NSBezierPath(rect: rect.insetBy(dx: half, dy: half))
        path.lineWidth = borderW
        path.stroke()
    }
}

/// Move-handle glyphs, cached by tint and appearance: building a configured SF
/// Symbol inside draw() re-runs CoreSVG instantiation per handle per redraw. Main-thread only.
enum MoveHandleSymbol {
    private static var cache: [String: NSImage] = [:]

    static func image(description: String, tint: NSColor) -> NSImage? {
        let key = "\(description)|\(tint)|\(NSApp.effectiveAppearance.name.rawValue)"
        if let hit = cache[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: description)?
            .withSymbolConfiguration(config) else { return nil }
        cache[key] = image
        return image
    }
}

// Flipped so document coordinates match the view model's top-down layout. The
// whole sync happens in sync(); drags animate through applyDragFrames.
final class GridDocumentView: NSView {
    weak var coordinator: GridCoordinator?
    override var isFlipped: Bool { true }

    // First clicks in an inactive window must act on the grid, not merely activate the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// In select mode the grid itself owns the keys (there is no caret), so it
    /// must be able to take first responder; the editor takes over in edit mode.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let coordinator, let cell = coordinator.viewModel.focusedCell,
              let action = coordinator.viewModel.handleGridKey(event, from: cell) else {
            super.keyDown(with: event)
            return
        }
        executeGridKeyAction(action)
    }

    /// Finishes a grid keystroke the view model decided: the first-responder
    /// switch and any caret or insert the model can't reach.
    func executeGridKeyAction(_ action: GridKeyAction) {
        switch action {
        case .moved:
            // Selection moved; park on the grid so the caret follows the mode.
            window?.makeFirstResponder(self)
        case .beginEditing(let insert):
            window?.makeFirstResponder(editor)
            if let insert {
                // Typing replaces the whole content; the caret lands after it.
                editor.insertText(insert,
                                  replacementRange: NSRange(location: 0, length: editor.string.count))
            } else {
                // F2: begin editing with the caret at the end of the content.
                editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
            }
        case .clearCell, .clearRange:
            // Content already changed in the model; sync() repaints, and the
            // first responder is already correct for the current mode.
            break
        case .endEditing, .clearFocus:
            window?.makeFirstResponder(self)
        }
    }

    // MARK: - Select-mode edit actions

    // In select mode the grid is first responder (no caret), so the Edit menu's
    // copy:/cut:/paste:/selectAll: land here. A block copies as a table; a lone
    // cell as content.
    @objc func copy(_ sender: Any?) {
        guard let viewModel = coordinator?.viewModel else { return }
        if viewModel.cellSelection != nil {
            _ = viewModel.copySelectedCells()
        } else {
            _ = viewModel.copyFocusedCellContent()
        }
    }

    @objc func cut(_ sender: Any?) {
        guard let viewModel = coordinator?.viewModel else { return }
        if viewModel.cellSelection != nil {
            _ = viewModel.cutSelectedCells()
        } else {
            _ = viewModel.cutFocusedCellContent()
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let viewModel = coordinator?.viewModel else { return }
        // A table on the pasteboard merges into this table at the focused cell;
        // with no cell focused it still promotes to its own document.
        if viewModel.pasteTableIntoCurrentTable() { return }
        if viewModel.pasteTableFromPasteboardIfTable() { return }
        if let f = viewModel.focusedCell {
            viewModel.pasteStringIntoCell(f)
        }
    }

    override func selectAll(_ sender: Any?) {
        coordinator?.viewModel.selectAllCells()
    }

    private var geometry: GridGeometry? {
        guard let coordinator else { return nil }
        return GridGeometry(viewModel: coordinator.viewModel)
    }

    // MARK: - Shared editor

    /// The grid's only text view: parked over the focused cell while editing,
    /// transparent so the drawn cell (background and border) shows through.
    private(set) lazy var editor: CellTextView = makeEditor()
    private lazy var editorClip = GridCellClipView()
    private var editorCell: GridCell?
    private var wiredEditor = false

    // Drawing stack mirroring the editor's TextKit metrics (3pt container inset,
    // 5pt line-fragment padding) so drawn and edited text land identically.
    private static let textInset: CGFloat = 3
    private let drawStorage = NSTextStorage()
    private lazy var drawLayout: NSLayoutManager = {
        let layout = NSLayoutManager()
        drawStorage.addLayoutManager(layout)
        layout.addTextContainer(drawContainer)
        return layout
    }()
    private lazy var drawContainer: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        return container
    }()

    // One layer-backed view per cell placement; syncCellViews() keeps the set
    // in step with the model and positions each at its cellRect.
    private var cellViews: [GridCell: GridCellView] = [:]
    // Last-synced content per cell, kept for the debugDrawnText() hook.
    private var drawnContents: [GridCell: NSAttributedString] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editorClip.addSubview(editor)
        addSubview(editorClip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Painting

    override func draw(_ dirtyRect: NSRect) {
        let geom = geometry
        // The padded container's separator tint shows through every 1pt gap;
        // the top-left corner box (and caption gutter) is control-colored. The
        // cells themselves are GridCellView subviews painted on top of this.
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let geom else { return }
        NSColor.separatorColor.setFill()
        NSRect(origin: .zero, size: geom.blockSize).fill()
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: geom.gridLeftEdge, height: geom.gridTopEdge).fill()
    }

    /// Lays out one cell's text in the shared stack and paints it clipped to
    /// the slot, at the editor's exact container origin. Called from each
    /// GridCellView's draw pass, so the shared stack is touched only on the
    /// main thread, one cell at a time.
    func drawCellText(_ content: NSAttributedString, alignment: NSTextAlignment, in rect: NSRect) {
        guard content.length > 0 else { return }
        let inset = Self.textInset
        let styled = NSMutableAttributedString(attributedString: content)
        if alignment != .left {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            styled.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: 0, length: styled.length))
        }
        drawStorage.setAttributedString(styled)
        drawContainer.size = NSSize(width: max(rect.width - 2 * inset, 1),
                                    height: .greatestFiniteMagnitude)
        let glyphs = drawLayout.glyphRange(for: drawContainer)
        guard glyphs.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        drawLayout.drawGlyphs(forGlyphRange: glyphs,
                              at: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Sync

    @MainActor
    func sync() {
        guard let coordinator else { return }
        let viewModel = coordinator.viewModel
        let geom = GridGeometry(viewModel: viewModel)
        if frame.size != geom.blockSize { setFrameSize(geom.blockSize) }

        syncCellViews(geom: geom, viewModel: viewModel, coordinator: coordinator)

        placeEditor(geom: geom, coordinator: coordinator)
        syncCaption(geom: geom, viewModel: viewModel, coordinator: coordinator)
        syncRowStrips(geom: geom, coordinator: coordinator)
        syncColumnStrips(geom: geom, coordinator: coordinator)
        syncResizeHandles(geom: geom, viewModel: viewModel, coordinator: coordinator)
        syncGapHighlights(geom: geom, coordinator: coordinator)
        syncSelectionBorder(geom: geom, viewModel: viewModel, coordinator: coordinator)
        restoreStackingOrder()
    }

    /// Keeps one GridCellView per placement in step with the model: creates and
    /// removes views as the shape changes, re-points content/focus/lift, and
    /// repositions each at its cellRect. Property setters redraw only real
    /// changes, so a keystroke touches one view, not the whole grid.
    @MainActor
    private func syncCellViews(geom: GridGeometry, viewModel: TableViewModel, coordinator: GridCoordinator) {
        let focused = viewModel.focusedCell
        let rangeActive = viewModel.cellSelection != nil
        var seen: Set<GridCell> = []
        var contents: [GridCell: NSAttributedString] = [:]
        for (row, slots) in viewModel.cachedPlacements.enumerated() {
            for p in slots {
                let cellKey = GridCell(row: row, column: p.cellIndex)
                seen.insert(cellKey)
                let view = cellViews[cellKey] ?? {
                    let v = GridCellView(frame: .zero)
                    v.documentView = self
                    addSubview(v)
                    cellViews[cellKey] = v
                    return v
                }()
                let rect = geom.cellRect(row: row, placement: p, coordinator: coordinator)
                if view.frame != rect { view.frame = rect }
                // The dragged row/column's floating copy is its only visible
                // representation, through the settle spring.
                view.isHidden = isHiddenByDrag(row: row, startCol: p.startCol, coordinator: coordinator)
                guard let cell = viewModel.cell(row: row, col: p.cellIndex) else { continue }
                view.content = cell.content
                view.alignment = cell.alignment
                view.isHeader = cell.isHeader
                view.isFocused = focused == cellKey
                view.isRangeActive = rangeActive
                contents[cellKey] = cell.content
            }
        }
        for (key, view) in cellViews where !seen.contains(key) {
            view.removeFromSuperview()
            cellViews.removeValue(forKey: key)
        }
        drawnContents = contents
    }

    // MARK: - Editor placement

    /// Parks the shared editor over the focused cell, re-pointing its content when
    /// focus moved; the drag appliers call it so the editor rides its cell through.
    @MainActor
    private func placeEditor(geom: GridGeometry, coordinator: GridCoordinator) {
        let viewModel = coordinator.viewModel
        guard let focused = viewModel.focusedCell,
              let (row, placement) = Self.placement(of: focused, in: viewModel.cachedPlacements) else {
            editorClip.isHidden = true
            editorCell = nil
            editor.modelCell = nil
            return
        }
        if !wiredEditor {
            wireEditor(coordinator: coordinator)
            wiredEditor = true
        }
        editor.delegate = coordinator
        let cellChanged = editorCell != focused
        editorCell = focused
        editor.modelCell = focused
        editor.modelStartCol = placement.startCol
        editor.gridVisualOrigin = VisualCell(row: row, column: placement.startCol)
        editor.gridVisualSpan = placement.colSpan
        editor.gridVisualRowSpan = placement.rowSpan
        editor.visualCellAt = { [weak coordinator] point in
            guard let coordinator else { return nil }
            let geom = GridGeometry(viewModel: coordinator.viewModel)
            return WYSIWYGView.visualCell(at: point,
                                          columnWidths: coordinator.viewModel.columnWidths,
                                          rowHeights: coordinator.viewModel.rowHeights,
                                          captionOffset: geom.captionBandHeight)
        }
        let rect = geom.cellRect(row: row, placement: placement, coordinator: coordinator)
        if editorClip.frame != rect { editorClip.frame = rect }
        // Hidden while the cell's row/column is dragged or settling: the
        // floating copy is the only visible representation.
        editorClip.isHidden = isHiddenByDrag(row: row, startCol: placement.startCol, coordinator: coordinator)
        let model = viewModel.cell(row: focused.row, col: focused.column)
        // Park a caret only while editing; in select mode the editor shows the
        // text but a caret would flash on the next first-responder switch.
        coordinator.apply(content: model?.content ?? NSAttributedString(),
                          revision: viewModel.contentRevision,
                          to: editor, alignment: model?.alignment ?? .left,
                          caret: cellChanged && viewModel.cellMode == .editing
                              ? NSRange(location: (model?.content.length ?? 0), length: 0) : nil)
    }

    static func placement(of cell: GridCell, in placements: [[Table.CellPlacement]]) -> (Int, Table.CellPlacement)? {
        guard cell.row >= 0, cell.row < placements.count else { return nil }
        guard let p = placements[cell.row].first(where: { $0.cellIndex == cell.column }) else { return nil }
        return (cell.row, p)
    }

    /// The editor is created once; handlers read `modelCell` at fire time, so
    /// re-pointing it across focus or switches keeps reporting the right cell.
    private func wireEditor(coordinator: GridCoordinator) {
        let viewModel = coordinator.viewModel
        editor.undoManagerOverride = viewModel.undoManager
        editor.didBecomeFirstResponderHandler = { [weak editor, weak viewModel] in
            guard let cell = editor?.modelCell else { return }
            viewModel?.focusedCell = cell
            // The editor only becomes first responder to edit, so ownership of
            // the keys (and the caret) transfers with it.
            viewModel?.cellMode = .editing
        }
        editor.flushPendingEditsHandler = { [weak viewModel] in
            viewModel?.closeTypingGroup()
        }
        editor.keyCommandHandler = { [weak self, weak editor, weak viewModel] event in
            guard let cell = editor?.modelCell,
                  let action = viewModel?.handleGridKey(event, from: cell) else { return false }
            self?.executeGridKeyAction(action)
            return true
        }
        editor.cellCommandHandler = { [weak editor, weak viewModel] command in
            guard let cell = editor?.modelCell else { return }
            switch command {
            case .addRowAbove: viewModel?.addRow(adjacentTo: cell, after: false)
            case .addRowBelow: viewModel?.addRow(adjacentTo: cell, after: true)
            case .addColumnLeft: viewModel?.addColumn(adjacentTo: cell, after: false)
            case .addColumnRight: viewModel?.addColumn(adjacentTo: cell, after: true)
            case .duplicateRow: viewModel?.duplicateRow(adjacentTo: cell, after: true)
            case .duplicateColumn: viewModel?.duplicateColumn(adjacentTo: cell, after: true)
            }
        }
        editor.cellCommandValidator = { [weak editor, weak viewModel] command in
            guard let cell = editor?.modelCell else { return true }
            switch command {
            case .duplicateRow: return viewModel?.canDuplicateRow(cell.row) ?? true
            case .duplicateColumn: return viewModel?.canDuplicateColumn(editor?.modelStartCol ?? cell.column) ?? true
            default: return true
            }
        }
        editor.cellRangeHandler = { [weak viewModel] range in
            viewModel?.cellSelection = range
        }
        editor.copyCellsHandler = { [weak viewModel] in
            viewModel?.copySelectedCells() ?? false
        }
        editor.pasteTableHandler = { [weak viewModel] in
            viewModel?.pasteTableFromPasteboardIfTable() ?? false
        }
        editor.colspanCurrent = { [weak editor, weak viewModel] in
            guard let cell = editor?.modelCell else { return 1 }
            return viewModel?.cell(row: cell.row, col: cell.column)?.colspan ?? 1
        }
        editor.colspanSet = { [weak editor, weak viewModel] span in
            guard let cell = editor?.modelCell else { return }
            viewModel?.setColspan(span, for: cell)
        }
    }

    private func makeEditor() -> CellTextView {
        // Explicit TextKit 1 stack at creation: touching .layoutManager on a default
        // (TextKit 2) view switches layout systems mid-setup and renders blank.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = CellTextView(frame: .zero, textContainer: container)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        // Undo is owned by the shared editor manager, not the text view.
        textView.allowsUndo = false
        // The document paints the cell's background and border; the editor
        // must stay transparent or it would mask them.
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.font = font
        // Typed characters must carry the model's attributes, or every
        // keystroke looks "changed" and gets replaced mid-edit.
        textView.typingAttributes = NSTextViewRepresentable.baseAttributes(font: font)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 3, height: 3)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        // The clip container sizes the editor; autoresizing would fight it.
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    // MARK: - Mouse

    /// The origin slot of a press-drag started on the document view (a click
    /// on the focused cell goes to the parked editor instead).
    private struct DragOrigin {
        var row: Int
        var startCol: Int
        var colSpan: Int
        var rowSpan: Int
    }
    private var dragOrigin: DragOrigin?

    /// Clicks reach the document view only outside the parked editor: select the hit
    /// cell with no caret. The caret appears when the user clicks the already-focused
    /// cell again, which the editor receives and turns into an edit.
    override func mouseDown(with event: NSEvent) {
        guard let coordinator, let geom = geometry else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let (row, placement) = cellRow(at: point, geom: geom, coordinator: coordinator) else { return }
        let viewModel = coordinator.viewModel
        viewModel.focusedCell = GridCell(row: row, column: placement.cellIndex)
        viewModel.cellSelection = nil
        viewModel.cellMode = .selected
        viewModel.resetNavigation()
        dragOrigin = DragOrigin(row: row, startCol: placement.startCol,
                                colSpan: placement.colSpan, rowSpan: placement.rowSpan)
        placeEditor(geom: geom, coordinator: coordinator)
        window?.makeFirstResponder(self)
    }

    /// A press-drag from any cell grows a range selection, mirroring the editor's
    /// own drag so formatting's whole-cell targets work from a fresh click.
    override func mouseDragged(with event: NSEvent) {
        guard let coordinator, let geom = geometry, let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = WYSIWYGView.visualCell(at: point,
                                               columnWidths: coordinator.viewModel.columnWidths,
                                               rowHeights: coordinator.viewModel.rowHeights,
                                               captionOffset: geom.captionBandHeight) else { return }
        coordinator.viewModel.cellSelection = VisualCellRange(
            rowStart: min(origin.row, hit.row),
            rowEnd: max(origin.row + origin.rowSpan - 1, hit.row),
            colStart: min(origin.startCol, hit.column),
            colEnd: max(origin.startCol + origin.colSpan - 1, hit.column))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    /// Right-click must offer the clicked cell's menu even when focus sits elsewhere: re-point
    /// the editor, then forward. Keyboard focus is not claimed (the menu targets it directly).
    override func rightMouseDown(with event: NSEvent) {
        guard let coordinator, let geom = geometry else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let (row, placement) = cellRow(at: point, geom: geom, coordinator: coordinator) else { return }
        let target = GridCell(row: row, column: placement.cellIndex)
        if coordinator.viewModel.focusedCell != target {
            coordinator.viewModel.focusedCell = target
        }
        placeEditor(geom: geom, coordinator: coordinator)
        editor.rightMouseDown(with: event)
    }

    /// Top-down scan: a point inside a rowspan cell's tall rect belongs to
    /// the origin's slot, and covered rows hold no own slot there.
    private func cellRow(at point: NSPoint, geom: GridGeometry,
                         coordinator: GridCoordinator) -> (Int, Table.CellPlacement)? {
        for (row, slots) in coordinator.viewModel.cachedPlacements.enumerated() {
            for p in slots where geom.cellRect(row: row, placement: p, coordinator: coordinator).contains(point) {
                return (row, p)
            }
        }
        return nil
    }

    /// Verification hook: every drawn visual cell's document-coordinate frame.
    @MainActor
    func debugVisualFrames() -> [(visual: VisualCell, cell: GridCell, frame: NSRect)] {
        guard let coordinator else { return [] }
        let geom = GridGeometry(viewModel: coordinator.viewModel)
        return coordinator.viewModel.cachedPlacements.enumerated().flatMap { row, slots in
            slots.map {
                (VisualCell(row: row, column: $0.startCol), GridCell(row: row, column: $0.cellIndex),
                 geom.cellRect(row: row, placement: $0, coordinator: coordinator))
            }
        }
    }

    /// Verification hook: the text the paint pass will draw per cell, straight from the last sync.
    @MainActor
    func debugDrawnText() -> [GridCell: String] {
        drawnContents.mapValues { $0.string }
    }

    // MARK: - Caption

    @MainActor
    private func syncCaption(geom: GridGeometry, viewModel: TableViewModel, coordinator: GridCoordinator) {
        guard viewModel.hasCaption else {
            coordinator.captionField?.removeFromSuperview()
            coordinator.captionField = nil
            return
        }
        let field: NSTextField
        if let existing = coordinator.captionField {
            field = existing
        } else {
            field = NSTextField()
            field.font = .preferredFont(forTextStyle: .headline)
            field.alignment = .center
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.delegate = coordinator
            field.target = coordinator
            field.action = #selector(GridCoordinator.captionChanged(_:))
            field.toolTip = "Table caption"
            coordinator.captionField = field
            addSubview(field)
        }
        field.frame = NSRect(x: geom.gridLeftEdge, y: WYSIWYGView.divider + WYSIWYGView.columnGutterHeight + WYSIWYGView.divider,
                             width: geom.gridColumnsWidth, height: WYSIWYGView.captionHeight - 2 * WYSIWYGView.divider)
        let captionText = viewModel.captionBinding.wrappedValue
        if field.stringValue != captionText {
            field.stringValue = captionText
        }
    }

    // MARK: - Row / column move strips

    @MainActor
    private func syncRowStrips(geom: GridGeometry, coordinator: GridCoordinator) {
        let count = viewModel?.table.rows.count ?? 0
        let keep = Set(0..<count)
        for (row, strip) in coordinator.rowStrips where !keep.contains(row) {
            strip.removeFromSuperview()
            coordinator.rowStrips.removeValue(forKey: row)
        }
        for row in 0..<count {
            let strip: RowMoveHandleView
            if let existing = coordinator.rowStrips[row] {
                strip = existing
            } else {
                strip = RowMoveHandleView(row: row)
                strip.documentView = self
                coordinator.rowStrips[row] = strip
                addSubview(strip)
            }
            strip.frame = NSRect(x: WYSIWYGView.divider,
                                 y: geom.gridTopEdge + geom.localRowTop(row) + geom.rowOffset(row, coordinator: coordinator),
                                 width: WYSIWYGView.gutterWidth,
                                 height: geom.rowHeight(row))
            strip.needsDisplay = true
        }
    }

    @MainActor
    private func syncColumnStrips(geom: GridGeometry, coordinator: GridCoordinator) {
        let count = viewModel?.columnWidths.count ?? 0
        let keep = Set(0..<count)
        for (col, strip) in coordinator.columnStrips where !keep.contains(col) {
            strip.removeFromSuperview()
            coordinator.columnStrips.removeValue(forKey: col)
        }
        for col in 0..<count {
            let strip: ColumnMoveHandleView
            if let existing = coordinator.columnStrips[col] {
                strip = existing
            } else {
                strip = ColumnMoveHandleView(col: col)
                strip.documentView = self
                coordinator.columnStrips[col] = strip
                addSubview(strip)
            }
            strip.frame = NSRect(x: geom.gridLeftEdge + geom.localColumnLeft(col) + geom.columnShift(col, coordinator: coordinator),
                                 y: WYSIWYGView.divider,
                                 width: geom.columnWidth(col),
                                 height: WYSIWYGView.columnGutterHeight)
            strip.needsDisplay = true
        }
    }

    // MARK: - Resize handles (boundary strips inside the cell layer)

    @MainActor
    private func syncResizeHandles(geom: GridGeometry, viewModel: TableViewModel, coordinator: GridCoordinator) {
        let colCount = viewModel.columnWidths.count
        let rowKeep = Set(0..<max(rowCount(viewModel) - 1, 0))
        for (row, handle) in coordinator.rowResizeHandles where !rowKeep.contains(row) {
            handle.removeFromSuperview()
            coordinator.rowResizeHandles.removeValue(forKey: row)
        }
        for row in 0..<max(rowCount(viewModel) - 1, 0) {
            let handle: GridResizeHandleView
            if let existing = coordinator.rowResizeHandles[row] {
                handle = existing
            } else {
                handle = GridResizeHandleView(axis: .vertical, index: row)
                handle.documentView = self
                coordinator.rowResizeHandles[row] = handle
                addSubview(handle)
            }
            handle.frame = NSRect(x: geom.gridLeftEdge,
                                  y: geom.gridTopEdge + geom.localRowTop(row) + geom.rowHeight(row)
                                      + WYSIWYGView.divider / 2 - WYSIWYGView.handleThickness / 2,
                                  width: geom.gridColumnsWidth,
                                  height: WYSIWYGView.handleThickness)
        }
        let colBoundaryKeep = Set((0..<max(colCount - 1, 0)).filter { viewModel.canResizeBoundary(afterCol: $0) })
        for (col, handle) in coordinator.columnResizeHandles where !colBoundaryKeep.contains(col) {
            handle.removeFromSuperview()
            coordinator.columnResizeHandles.removeValue(forKey: col)
        }
        for col in 0..<max(colCount - 1, 0) where viewModel.canResizeBoundary(afterCol: col) {
            let handle: GridResizeHandleView
            if let existing = coordinator.columnResizeHandles[col] {
                handle = existing
            } else {
                handle = GridResizeHandleView(axis: .horizontal, index: col)
                handle.documentView = self
                coordinator.columnResizeHandles[col] = handle
                addSubview(handle)
            }
            handle.frame = NSRect(x: geom.gridLeftEdge + geom.localColumnLeft(col) + geom.columnWidth(col)
                                      + WYSIWYGView.divider / 2 - WYSIWYGView.handleThickness / 2,
                                  y: geom.gridTopEdge,
                                  width: WYSIWYGView.handleThickness,
                                  height: geom.gridHeight)
        }
    }

    private func rowCount(_ viewModel: TableViewModel) -> Int { viewModel.rowHeights.count }

    // MARK: - Gap highlights + selection border

    @MainActor
    private func syncGapHighlights(geom: GridGeometry, coordinator: GridCoordinator) {
        let viewModel = coordinator.viewModel
        if let source = coordinator.rowDrag.dragged, let target = coordinator.rowDrag.target, target != source {
            let view = coordinator.rowGapHighlight ?? {
                let v = GapHighlightView()
                coordinator.rowGapHighlight = v
                addSubview(v)
                return v
            }()
            // A 2pt line at the slot's top edge; it snaps to the landing slot
            // instead of shading the whole band.
            let y = WYSIWYGView.slotTop(source: source, target: target, rowHeights: viewModel.rowHeights)
                + geom.gridTopEdge - WYSIWYGView.divider
            view.frame = NSRect(x: geom.gridLeftEdge, y: y, width: geom.gridColumnsWidth, height: 2)
            view.isHidden = false
        } else {
            coordinator.rowGapHighlight?.isHidden = true
        }
        if let source = coordinator.columnDrag.dragged, let target = coordinator.columnDrag.target, target != source {
            let view = coordinator.columnGapHighlight ?? {
                let v = GapHighlightView()
                coordinator.columnGapHighlight = v
                addSubview(v)
                return v
            }()
            let x = geom.gridLeftEdge - WYSIWYGView.divider
                + WYSIWYGView.slotLeft(source: source, target: target, widths: viewModel.columnWidths)
            view.frame = NSRect(x: x, y: geom.gridTopEdge, width: 2, height: geom.gridHeight - 2 * WYSIWYGView.divider)
            view.isHidden = false
        } else {
            coordinator.columnGapHighlight?.isHidden = true
        }
    }

    @MainActor
    private func syncSelectionBorder(geom: GridGeometry, viewModel: TableViewModel, coordinator: GridCoordinator) {
        if let rect = geom.selectionRect() {
            let view = coordinator.selectionBorder ?? {
                let v = SelectionBorderView()
                coordinator.selectionBorder = v
                addSubview(v)
                return v
            }()
            view.frame = rect
            view.isHidden = false
            view.needsDisplay = true
        } else {
            coordinator.selectionBorder?.isHidden = true
        }
    }

    /// Editor (bottom), then strips/handles, then highlights, then the
    /// selection border, then the drag's floating copies on top; re-adding an
    /// existing subview moves it front.
    private func restoreStackingOrder() {
        guard let coordinator else { return }
        // The cell views sit at the bottom; the editor clip must paint the
        // focused cell's text on top of them, then the gutters and overlays.
        addSubview(editorClip)
        for (_, strip) in coordinator.rowStrips { addSubview(strip) }
        for (_, strip) in coordinator.columnStrips { addSubview(strip) }
        for (_, handle) in coordinator.rowResizeHandles { addSubview(handle) }
        for (_, handle) in coordinator.columnResizeHandles { addSubview(handle) }
        if let field = coordinator.captionField { addSubview(field) }
        if let gap = coordinator.rowGapHighlight { addSubview(gap) }
        if let gap = coordinator.columnGapHighlight { addSubview(gap) }
        if let border = coordinator.selectionBorder { addSubview(border) }
        if let floating = coordinator.rowFloating { addSubview(floating) }
        if let floating = coordinator.columnFloating { addSubview(floating) }
    }

    // MARK: - Drag frame application (called by the handle views)

    /// The cells a drag's floating copy stands in for: the dragged row/column
    /// and the settling one, until its spring lands.
    private func isHiddenByDrag(row: Int, startCol: Int, coordinator: GridCoordinator) -> Bool {
        row == coordinator.rowDrag.dragged
            || row == coordinator.rowDrag.settleSlot
            || startCol == coordinator.columnDrag.dragged
            || startCol == coordinator.columnDrag.settleSlot
    }

    /// Snapshots a band of the document into a floating overlay that tracks
    /// the cursor; the real cells hide while it is up.
    @MainActor
    func makeFloatingCopy(of band: NSRect) -> DragFloatingView {
        let view = DragFloatingView(frame: band)
        // The caching rep is sized for the window's backing scale, so the
        // snapshot stays sharp on Retina.
        if let rep = bitmapImageRepForCachingDisplay(in: band) {
            cacheDisplay(in: band, to: rep)
            let image = NSImage(size: band.size)
            image.addRepresentation(rep)
            view.image = image
        }
        addSubview(view)
        return view
    }

    @MainActor
    func applyRowDragFrames(coordinator: GridCoordinator) {
        guard let geom = geometry else { return }
        let viewModel = coordinator.viewModel
        let dragged = coordinator.rowDrag.dragged
        // The dragged row's cells hide behind its floating copy; path rows
        // reflow in one frame, the way Numbers does.
        for (row, slots) in viewModel.cachedPlacements.enumerated() {
            for p in slots {
                guard let view = cellViews[GridCell(row: row, column: p.cellIndex)] else { continue }
                let hidden = isHiddenByDrag(row: row, startCol: p.startCol, coordinator: coordinator)
                if view.isHidden != hidden { view.isHidden = hidden }
                if hidden { continue }
                let rect = geom.cellRect(row: row, placement: p, coordinator: coordinator)
                if view.frame.origin != rect.origin { view.setFrameOrigin(rect.origin) }
            }
        }
        for row in 0..<viewModel.table.rows.count {
            guard let strip = coordinator.rowStrips[row] else { continue }
            // The dragged row's grip rides the floating copy 1:1.
            let y = row == dragged
                ? geom.gridTopEdge + geom.localRowTop(row) + coordinator.rowDrag.translation
                : geom.gridTopEdge + geom.localRowTop(row) + geom.rowOffset(row, coordinator: coordinator)
            let origin = NSPoint(x: strip.frame.minX, y: y)
            if strip.frame.origin != origin { strip.setFrameOrigin(origin) }
        }
        syncGapHighlights(geom: geom, coordinator: coordinator)
        placeEditor(geom: geom, coordinator: coordinator)
    }

    @MainActor
    func applyColumnDragFrames(coordinator: GridCoordinator) {
        guard let geom = geometry else { return }
        let viewModel = coordinator.viewModel
        let dragged = coordinator.columnDrag.dragged
        for (row, slots) in viewModel.cachedPlacements.enumerated() {
            for p in slots {
                guard let view = cellViews[GridCell(row: row, column: p.cellIndex)] else { continue }
                let hidden = isHiddenByDrag(row: row, startCol: p.startCol, coordinator: coordinator)
                if view.isHidden != hidden { view.isHidden = hidden }
                if hidden { continue }
                let rect = geom.cellRect(row: row, placement: p, coordinator: coordinator)
                if view.frame.origin != rect.origin { view.setFrameOrigin(rect.origin) }
            }
        }
        for col in 0..<viewModel.columnWidths.count {
            guard let strip = coordinator.columnStrips[col] else { continue }
            let x = col == dragged
                ? geom.gridLeftEdge + geom.localColumnLeft(col) + coordinator.columnDrag.translation
                : geom.gridLeftEdge + geom.localColumnLeft(col) + geom.columnShift(col, coordinator: coordinator)
            let origin = NSPoint(x: x, y: strip.frame.minY)
            if strip.frame.origin != origin { strip.setFrameOrigin(origin) }
        }
        syncGapHighlights(geom: geom, coordinator: coordinator)
        placeEditor(geom: geom, coordinator: coordinator)
    }

    /// Springs the floating copy from the cursor into the moved row/column's
    /// new slot; the real cells stay hidden until it lands.
    @MainActor
    func settleFloating(vertical: Bool, coordinator: GridCoordinator) {
        guard let geom = geometry else { return }
        let drag = vertical ? coordinator.rowDrag : coordinator.columnDrag
        guard let slot = drag.settleSlot,
              let floating = vertical ? coordinator.rowFloating : coordinator.columnFloating else { return }
        let band: NSRect
        if vertical {
            band = NSRect(x: geom.gridLeftEdge,
                          y: geom.gridTopEdge + geom.localRowTop(slot),
                          width: geom.gridColumnsWidth,
                          height: geom.rowHeight(slot))
        } else {
            band = NSRect(x: geom.gridLeftEdge + geom.localColumnLeft(slot),
                          y: geom.gridTopEdge,
                          width: geom.columnWidth(slot),
                          height: geom.gridHeight - 2 * WYSIWYGView.divider)
        }
        // The floating layer is detached (anchor 0,0) and its position IS the
        // frame's origin in the document view's flipped space, so drive the
        // spring from the layer's real position — not a recomputed center.
        let fromPos = floating.layer?.position ?? .zero
        floating.frame = band
        let toPos = floating.layer?.position ?? .zero
        // perceptualDuration/bounce are read-only; the convenience init is
        // how they get set.
        let spring = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.2)
        spring.keyPath = "position"
        spring.fromValue = NSValue(point: fromPos)
        spring.toValue = NSValue(point: toPos)
        // A faster second drop can replace the floating copy mid-flight; only
        // tear down this settle's own view and slot.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak coordinator, weak floating, slot] in
            MainActor.assumeIsolated {
                guard let self, let coordinator else { return }
                floating?.removeFromSuperview()
                if vertical {
                    if coordinator.rowFloating === floating { coordinator.rowFloating = nil }
                    if coordinator.rowDrag.settleSlot == slot { coordinator.rowDrag.settleSlot = nil }
                } else {
                    if coordinator.columnFloating === floating { coordinator.columnFloating = nil }
                    if coordinator.columnDrag.settleSlot == slot { coordinator.columnDrag.settleSlot = nil }
                }
                self.sync()
            }
        }
        floating.layer?.add(spring, forKey: "settle")
        CATransaction.commit()
    }

    private var viewModel: TableViewModel? { coordinator?.viewModel }
}

@MainActor
extension GridCoordinator {
    @objc func captionChanged(_ sender: NSTextField) {
        parent?.viewModel.captionBinding.wrappedValue = sender.stringValue
    }
}

// MARK: - Overlay views

/// A 2pt accent line marking the dragged row/column's landing slot; it snaps
/// to the slot edge rather than shading the whole band.
final class GapHighlightView: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        bounds.fill()
    }

    // Paint-only overlays must not swallow the clicks meant for the cells (or editor) underneath them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A 1:1 snapshot of the dragged row/column that tracks the cursor; the real
/// cells hide while it is up, and it springs into the final slot on drop.
final class DragFloatingView: NSView {
    var image: NSImage?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed so the settle spring moves the cached snapshot without
        // redrawing it; the image itself is drawn through the flipped view.
        wantsLayer = true
        alphaValue = 0.8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
    }
    // Paint-only overlays must not swallow the clicks meant for the cells underneath them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SelectionBorderView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // strokeBorder semantics: the accent line hugs the rect from inside.
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Move handles (gutter strips)

/// Shared mouse-drag plumbing: a local event monitor turns screen-space movement
/// into a signed translation (down/right positive), honoring a minimum start distance.
enum GridDragGesture {
    /// Drives a drag; returns the monitor-owning token via callbacks.
    @discardableResult
    static func start(event: NSEvent, minimumDistance: CGFloat, axisIsVertical: Bool,
                      onChanged: @escaping (_ translation: CGFloat, _ first: Bool) -> Void,
                      onEnded: @escaping (_ translation: CGFloat) -> Void) -> Any? {
        let startScreen = NSEvent.mouseLocation
        var translation: CGFloat = 0
        var started = false
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { ev in
            let now = NSEvent.mouseLocation
            let raw = axisIsVertical ? startScreen.y - now.y : now.x - startScreen.x
            switch ev.type {
            case .leftMouseDragged:
                guard abs(raw) >= minimumDistance else { return nil }
                translation = raw
                onChanged(raw, !started)
                started = true
                return nil
            case .leftMouseUp:
                if let monitor { NSEvent.removeMonitor(monitor) }
                if started {
                    onEnded(translation)
                } else {
                    onEnded(0)
                }
                return nil
            default:
                return nil
            }
        }
        return monitor
    }
}

// Row-gutter strip; dragging it moves its row, the drop commits as one undo
// step. Rows a merge touches can't travel alone, so their grips go blank.
final class RowMoveHandleView: NSView {
    let row: Int
    weak var documentView: GridDocumentView?
    private var hovering = false
    private var monitor: Any?

    override var isFlipped: Bool { true }

    init(row: Int) {
        self.row = row
        super.init(frame: .zero)
        toolTip = "Drag to move this row"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var canMove: Bool {
        documentView?.coordinator?.viewModel.canMoveRow(row) ?? false
    }

    private var isDragged: Bool { documentView?.coordinator?.rowDrag.dragged == row }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard canMove else { return }
        if isDragged {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            bounds.fill()
        }
        let color: NSColor = isDragged ? .controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(hovering ? 0.9 : 0.45)
        guard let symbol = MoveHandleSymbol.image(description: "Move row", tint: color) else { return }
        let side: CGFloat = 10
        let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                          width: side, height: side)
        symbol.draw(in: rect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func resetCursorRects() {
        if canMove { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard canMove, let documentView, let coordinator = documentView.coordinator else {
            super.mouseDown(with: event)
            return
        }
        var snapshot: EditorSnapshot?
        var band: NSRect = .zero
        monitor = GridDragGesture.start(event: event, minimumDistance: 3, axisIsVertical: true,
            onChanged: { [weak self, weak coordinator, weak documentView] translation, first in
                guard let coordinator, let documentView else { return }
                if first {
                    snapshot = coordinator.viewModel.currentSnapshot()
                    coordinator.rowDrag.settleSlot = nil
                    coordinator.rowDrag.reset()
                    coordinator.rowDrag.dragged = self?.row
                    coordinator.rowDrag.target = self?.row
                    // Lift the row out of the flow: snapshot its band for the
                    // floating copy; the real cells hide and path rows reflow.
                    let geom = GridGeometry(viewModel: coordinator.viewModel)
                    band = NSRect(x: geom.gridLeftEdge,
                                  y: geom.gridTopEdge + geom.localRowTop(self?.row ?? 0),
                                  width: geom.gridColumnsWidth,
                                  height: geom.rowHeight(self?.row ?? 0))
                    coordinator.rowFloating = documentView.makeFloatingCopy(of: band)
                }
                coordinator.rowDrag.translation = translation
                coordinator.rowFloating?.frame.origin = NSPoint(x: band.minX, y: band.minY + translation)
                let landing = Self.landingIndex(translation: translation, index: self?.row ?? 0,
                                                count: coordinator.viewModel.table.rows.count,
                                                sizes: coordinator.viewModel.rowHeights,
                                                fallback: TableViewModel.defaultRowHeight)
                coordinator.rowDrag.target = landing
                documentView.applyRowDragFrames(coordinator: coordinator)
            },
            onEnded: { [weak self, weak coordinator, weak documentView] translation in
                guard let self, let coordinator, let documentView else { return }
                defer { coordinator.rowDrag.reset() }
                guard let before = snapshot, translation != 0 else {
                    coordinator.rowFloating?.removeFromSuperview()
                    coordinator.rowFloating = nil
                    documentView.sync()
                    return
                }
                let dest = Self.landingIndex(translation: translation, index: self.row,
                                             count: coordinator.viewModel.table.rows.count,
                                             sizes: coordinator.viewModel.rowHeights,
                                             fallback: TableViewModel.defaultRowHeight)
                let source = self.row
                // A merge crossing the travel band makes the move a no-op;
                // spring the copy back to the row's own slot.
                let slot = coordinator.viewModel.canMoveRow(from: source, to: dest) ? dest : source
                if slot != source {
                    coordinator.viewModel.moveRow(from: source, to: dest, before: before)
                }
                // The moved row's cells stay hidden while the floating copy
                // springs into its slot.
                coordinator.rowDrag.settleSlot = slot
                documentView.sync()
                documentView.settleFloating(vertical: true, coordinator: coordinator)
            })
        needsDisplay = true
    }
}

// Top-strip grab; dragging moves the column. Colspan-covered columns show a
// blank strip: they can't move cleanly, so they stay un-grabbable.
final class ColumnMoveHandleView: NSView {
    let col: Int
    weak var documentView: GridDocumentView?
    private var hovering = false
    private var monitor: Any?

    override var isFlipped: Bool { true }

    init(col: Int) {
        self.col = col
        super.init(frame: .zero)
        toolTip = "Drag to move this column"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var canMove: Bool {
        documentView?.coordinator?.viewModel.canMoveColumn(col) ?? false
    }

    private var isDragged: Bool { documentView?.coordinator?.columnDrag.dragged == col }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard canMove else { return }
        if isDragged {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            bounds.fill()
        }
        // Rotated row grip: "line.3.vertical" is not a real SF Symbol name,
        // so the horizontal one turns to stand in.
        let color: NSColor = isDragged ? .controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(hovering ? 0.9 : 0.45)
        guard let symbol = MoveHandleSymbol.image(description: "Move column", tint: color) else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: 90)
        transform.concat()
        symbol.draw(at: NSPoint(x: -symbol.size.width / 2, y: -symbol.size.height / 2),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func resetCursorRects() {
        if canMove { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard canMove, let documentView, let coordinator = documentView.coordinator else {
            super.mouseDown(with: event)
            return
        }
        var snapshot: EditorSnapshot?
        var band: NSRect = .zero
        monitor = GridDragGesture.start(event: event, minimumDistance: 3, axisIsVertical: false,
            onChanged: { [weak self, weak coordinator, weak documentView] translation, first in
                guard let coordinator, let documentView else { return }
                if first {
                    snapshot = coordinator.viewModel.currentSnapshot()
                    coordinator.columnDrag.settleSlot = nil
                    coordinator.columnDrag.reset()
                    coordinator.columnDrag.dragged = self?.col
                    coordinator.columnDrag.target = self?.col
                    // Lift the column out of the flow: snapshot its band for
                    // the floating copy; the real cells hide and path columns
                    // reflow.
                    let geom = GridGeometry(viewModel: coordinator.viewModel)
                    band = NSRect(x: geom.gridLeftEdge + geom.localColumnLeft(self?.col ?? 0),
                                  y: geom.gridTopEdge,
                                  width: geom.columnWidth(self?.col ?? 0),
                                  height: geom.gridHeight - 2 * WYSIWYGView.divider)
                    coordinator.columnFloating = documentView.makeFloatingCopy(of: band)
                }
                coordinator.columnDrag.translation = translation
                coordinator.columnFloating?.frame.origin = NSPoint(x: band.minX + translation, y: band.minY)
                let landing = Self.landingIndex(translation: translation, index: self?.col ?? 0,
                                                count: coordinator.viewModel.columnWidths.count,
                                                sizes: coordinator.viewModel.columnWidths,
                                                fallback: TableViewModel.defaultColumnWidth)
                coordinator.columnDrag.target = landing
                documentView.applyColumnDragFrames(coordinator: coordinator)
            },
            onEnded: { [weak self, weak coordinator, weak documentView] translation in
                guard let self, let coordinator, let documentView else { return }
                defer { coordinator.columnDrag.reset() }
                guard let before = snapshot, translation != 0 else {
                    coordinator.columnFloating?.removeFromSuperview()
                    coordinator.columnFloating = nil
                    documentView.sync()
                    return
                }
                let dest = Self.landingIndex(translation: translation, index: self.col,
                                             count: coordinator.viewModel.columnWidths.count,
                                             sizes: coordinator.viewModel.columnWidths,
                                             fallback: TableViewModel.defaultColumnWidth)
                let source = self.col
                // A merge crossing the travel band makes the move a no-op;
                // spring the copy back to the column's own slot.
                let slot = coordinator.viewModel.canMoveColumn(from: source, to: dest) ? dest : source
                if slot != source {
                    coordinator.viewModel.moveColumn(from: source, to: dest, before: before)
                }
                // The moved column's cells stay hidden while the floating copy
                // springs into its slot.
                coordinator.columnDrag.settleSlot = slot
                documentView.sync()
                documentView.settleFloating(vertical: false, coordinator: coordinator)
            })
        needsDisplay = true
    }
}

// MARK: - Resize handles (one undo step per completed drag)

final class GridResizeHandleView: NSView {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    let index: Int
    weak var documentView: GridDocumentView?
    private var monitor: Any?

    override var isFlipped: Bool { true }

    init(axis: Axis, index: Int) {
        self.axis = axis
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let documentView, let coordinator = documentView.coordinator else {
            super.mouseDown(with: event)
            return
        }
        let viewModel = coordinator.viewModel
        var start: CGFloat?
        var snapshot: EditorSnapshot?
        let vertical = axis == .vertical
        monitor = GridDragGesture.start(event: event, minimumDistance: 2, axisIsVertical: vertical,
            onChanged: { [weak self] translation, first in
                guard let self else { return }
                if first {
                    start = vertical
                        ? (index < viewModel.rowHeights.count ? viewModel.rowHeights[index] : TableViewModel.defaultRowHeight)
                        : (index < viewModel.columnWidths.count ? viewModel.columnWidths[index] : TableViewModel.defaultColumnWidth)
                    snapshot = viewModel.currentSnapshot()
                }
                guard let base = start else { return }
                if vertical {
                    viewModel.setRowHeight(index, to: base + translation)
                } else {
                    viewModel.setColumnWidth(index, to: base + translation)
                }
            },
            onEnded: { [weak self] _ in
                guard self != nil else { return }
                start = nil
                if let before = snapshot {
                    viewModel.registerResizeUndo(name: vertical ? "Resize Row" : "Resize Column", before: before)
                }
                snapshot = nil
            })
    }
}

// MARK: - Landing index

extension RowMoveHandleView {
    /// Landing row for a drop at `translation`: count row centers above the
    /// drag point; dragging down past the row's own center reserves below.
    static func landingIndex(translation dy: CGFloat, index row: Int, count rawCount: Int,
                             sizes: [CGFloat], fallback: CGFloat) -> Int {
        let divider = WYSIWYGView.divider
        let count = max(rawCount, 1)
        func height(_ i: Int) -> CGFloat { i < sizes.count ? sizes[i] : fallback }
        var ownCenter = divider
        for i in 0..<min(row, count) { ownCenter += height(i) + divider }
        ownCenter += height(min(row, count - 1)) / 2
        let dragPoint = ownCenter + dy
        var above = 0
        var y = divider
        for i in 0..<count {
            if y + height(i) / 2 < dragPoint { above += 1 }
            y += height(i) + divider
        }
        let index = dy > 0 ? above - 1 : above
        return min(max(index, 0), count - 1)
    }
}

extension ColumnMoveHandleView {
    /// Landing column for a drop at `translation`: count column centers left of the
    /// drag point; dragging right past the column's own center reserves the right slot.
    static func landingIndex(translation dx: CGFloat, index col: Int, count rawCount: Int,
                             sizes: [CGFloat], fallback: CGFloat) -> Int {
        let divider = WYSIWYGView.divider
        let count = max(rawCount, 1)
        func width(_ i: Int) -> CGFloat { i < sizes.count ? sizes[i] : fallback }
        var ownCenter = divider
        for i in 0..<min(col, count) { ownCenter += width(i) + divider }
        ownCenter += width(min(col, count - 1)) / 2
        let dragPoint = ownCenter + dx
        var leftOf = 0
        var x = divider
        for i in 0..<count {
            if x + width(i) / 2 < dragPoint { leftOf += 1 }
            x += width(i) + divider
        }
        let index = dx > 0 ? leftOf - 1 : leftOf
        return min(max(index, 0), count - 1)
    }
}

// MARK: - Geometry

/// The layout math the SwiftUI WYSIWYGView carried, in padded-container document coordinates.
@MainActor
struct GridGeometry {
    let viewModel: TableViewModel

    private var divider: CGFloat { WYSIWYGView.divider }
    private var rowHeights: [CGFloat] { viewModel.rowHeights }
    private var columnWidths: [CGFloat] { viewModel.columnWidths }

    var captionBandHeight: CGFloat {
        viewModel.hasCaption ? WYSIWYGView.captionHeight + divider : 0
    }

    var gridColumnsWidth: CGFloat {
        columnWidths.reduce(0, +) + CGFloat(max(columnWidths.count - 1, 0)) * divider
    }

    var gridHeight: CGFloat {
        2 * divider + rowHeights.reduce(0, +) + CGFloat(max(rowHeights.count - 1, 0)) * divider
    }

    var gridLeftEdge: CGFloat { divider + WYSIWYGView.gutterWidth + divider }
    var gridTopEdge: CGFloat { divider + WYSIWYGView.columnGutterHeight + divider + captionBandHeight }

    var blockSize: NSSize {
        NSSize(width: gridLeftEdge + gridColumnsWidth + divider,
               height: gridTopEdge + gridHeight + divider)
    }

    func columnWidth(_ col: Int) -> CGFloat {
        col < columnWidths.count ? columnWidths[col] : TableViewModel.defaultColumnWidth
    }

    func rowHeight(_ row: Int) -> CGFloat {
        row < rowHeights.count ? rowHeights[row] : TableViewModel.defaultRowHeight
    }

    func localColumnLeft(_ col: Int) -> CGFloat {
        CGFloat(col) * divider + columnWidths.prefix(col).reduce(0, +)
    }

    func localRowTop(_ row: Int) -> CGFloat {
        CGFloat(row) * divider + rowHeights.prefix(row).reduce(0, +)
    }

    /// Height of a cell that towers over `rowSpan` rows, dividers included.
    func cellHeight(row: Int, rowSpan: Int) -> CGFloat {
        // @Observable partial invalidation can re-run a removed slot's content closure
        // with its captured row index against the new table, so bound index reads.
        guard row < rowHeights.count else { return TableViewModel.defaultRowHeight }
        var height = CGFloat(max(rowSpan - 1, 0)) * divider
        for spanned in row..<min(row + rowSpan, rowHeights.count) {
            height += rowHeight(spanned)
        }
        return height
    }

    // Rows between source and landing slot slide aside in one frame; the
    // dragged row itself is hidden behind its floating copy.
    func rowOffset(_ row: Int, coordinator: GridCoordinator) -> CGFloat {
        let drag = coordinator.rowDrag
        guard let source = drag.dragged, let target = drag.target, target != source else { return 0 }
        let step = rowHeight(source) + divider
        if target > source, row > source, row <= target { return -step }
        if target < source, row >= target, row < source { return step }
        return 0
    }

    func columnShift(_ col: Int, coordinator: GridCoordinator) -> CGFloat {
        let drag = coordinator.columnDrag
        guard let source = drag.dragged, let target = drag.target, target != source else { return 0 }
        let step = columnWidth(source) + divider
        if target > source, col > source, col <= target { return -step }
        if target < source, col >= target, col < source { return step }
        return 0
    }

    func cellRect(row: Int, placement p: Table.CellPlacement, coordinator: GridCoordinator) -> NSRect {
        NSRect(x: gridLeftEdge + localColumnLeft(p.startCol) + columnShift(p.startCol, coordinator: coordinator),
               y: gridTopEdge + localRowTop(row) + rowOffset(row, coordinator: coordinator),
               width: viewModel.cellWidth(startingAtCol: p.startCol, span: p.colSpan),
               height: cellHeight(row: row, rowSpan: p.rowSpan))
    }

    /// Leading edge of visual column i (i == count gives the trailing edge).
    func columnEdge(_ i: Int) -> CGFloat {
        var x = gridLeftEdge
        for j in 0..<min(i, columnWidths.count) { x += columnWidth(j) + divider }
        return x
    }

    /// Top edge of visual row j (j == count gives the bottom edge).
    func rowEdge(_ j: Int) -> CGFloat {
        var y = gridTopEdge
        for k in 0..<min(j, rowHeights.count) { y += rowHeight(k) + divider }
        return y
    }

    /// Bounding box of every cell intersecting the selection, so a merged
    /// cell that straddles the range edge is enclosed rather than cut.
    func selectionRect() -> NSRect? {
        guard let sel = viewModel.cellSelection, !viewModel.table.rows.isEmpty else { return nil }
        var left = CGFloat.greatestFiniteMagnitude, right = -CGFloat.greatestFiniteMagnitude
        var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
        for (row, slots) in viewModel.cachedPlacements.enumerated() {
            for p in slots where sel.intersects(row: row, rowSpan: p.rowSpan,
                                                startCol: p.startCol, span: p.colSpan) {
                left = min(left, columnEdge(p.startCol))
                // columnEdge past the last covered column lands a divider late.
                right = max(right, columnEdge(p.startCol + p.colSpan) - divider)
                top = min(top, rowEdge(row))
                bottom = max(bottom, rowEdge(row + p.rowSpan) - divider)
            }
        }
        guard right > left, bottom > top else { return nil }
        return NSRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
