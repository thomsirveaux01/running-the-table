import AppKit
import SwiftUI

/// The merged-cell grid as a single AppKit view instead of a nest of SwiftUI
/// ForEach/ZStack layers: one flipped document view hosts pooled CellTextViews
/// (one per model cell, reused across table switches) plus the gutter strips,
/// selection overlays, and move/resize handles, so switching tables re-points
/// existing text views instead of rebuilding the SwiftUI tree.
///
/// The document view occupies the same padded-container space the SwiftUI
/// layout drew into (1pt padding, separator-color background showing through
/// the 1pt gaps), so WYSIWYGView.visualCell's coordinate contract and the
/// gridlayout/rowbound probes' expected frames carry over unchanged.
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
/// never churn autosave or the undo stack (same contract the SwiftUI
/// RowDragState/ColumnDragState served before).
final class GridDragState {
    var dragged: Int?
    var target: Int?
    var translation: CGFloat = 0
    var settleSlot: Int?
    var settleOffset: CGFloat = 0

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

    // Pooled per-cell clip containers keyed by model cell (the editor is
    // their only subview; the container pins the clip width and floors the
    // slot height — see GridCellClipView).
    var cellViews: [GridCell: NSView] = [:]
    // Editors dropped by a table-shape change ride here instead of being
    // rebuilt from scratch (TextKit stack + container) on the way back.
    var spareCells: [NSView] = []
    var lastAppliedRevision: [GridCell: Int] = [:]
    var lastAppliedAlignment: [GridCell: NSTextAlignment] = [:]
    var lastFocused: [GridCell: Bool] = [:]
    // Landing-offset memory so only changed rows animate on a preview bump.
    var appliedRowOffsets: [Int: CGFloat] = [:]
    var appliedColumnOffsets: [Int: CGFloat] = [:]

    var rowStrips: [Int: RowMoveHandleView] = [:]
    var columnStrips: [Int: ColumnMoveHandleView] = [:]
    var rowResizeHandles: [Int: GridResizeHandleView] = [:]
    var columnResizeHandles: [Int: GridResizeHandleView] = [:]
    var captionField: NSTextField?
    var selectionBorder: SelectionBorderView?
    var rowGapHighlight: GapHighlightView?
    var columnGapHighlight: GapHighlightView?

    // AppKit echoes programmatic text/selection swaps back as delegate
    // callbacks; publishing those would mutate the model mid-view-update.
    var applyingProgrammaticContent = false

    var viewModel: TableViewModel { parent!.viewModel }

    // MARK: - Cell content / alignment (mirrors the representable's dual-path apply)

    /// Returns whether the write (or an alignment restyle) dirtied the text
    /// view, so sync() can skip invalidating cells nothing changed.
    @discardableResult
    func apply(content: NSAttributedString, revision: Int, to textView: CellTextView, alignment: NSTextAlignment) -> Bool {
        guard let cell = textView.modelCell else { return false }
        guard lastAppliedRevision[cell] != revision else { return false }
        lastAppliedRevision[cell] = revision
        // The storage carries the view-layer paragraph style but the model's
        // content is style-free, so compare with the style stripped to avoid
        // a swap (and IME-interrupting reset) on every revision bump.
        let current = textView.textStorage ?? NSAttributedString()
        if NSTextViewRepresentable.Coordinator.strippingParagraphStyle(current).isEqual(to: content) {
            return applyAlignmentIfNeeded(to: textView, alignment: alignment)
        }
        let savedSelection = textView.selectedRanges
        // Selection is only ever visible on the focused editor; restoring it
        // on the other ~40 cells per switch was pure layout work. Writing
        // leaves an unfocused editor at location 0, which is invisible.
        let restoreSelection = textView.window?.firstResponder === textView
        applyingProgrammaticContent = true
        textView.textStorage?.setAttributedString(content)
        if restoreSelection {
            // NSSelectionArray rejects empty arrays (raises, crashes) and
            // out-of-range values, e.g. after undo empties a cell.
            var selection = savedSelection.filter { $0.rangeValue.upperBound <= content.length }
            if selection.isEmpty {
                selection = [NSValue(range: NSRange(location: content.length, length: 0))]
            }
            textView.selectedRanges = selection
        }
        applyingProgrammaticContent = false
        // A left-aligned cell needs no write — style-free content already
        // renders left for LTR text — so skip the full-range paragraph-style
        // pass, the biggest per-cell cost in the swap.
        if alignment == .left {
            lastAppliedAlignment[cell] = .left
        } else {
            applyAlignment(to: textView, alignment: alignment)
        }
        return true
    }

    func applyAlignment(to textView: CellTextView, alignment: NSTextAlignment) {
        guard let cell = textView.modelCell else { return }
        lastAppliedAlignment[cell] = alignment
        guard let storage = textView.textStorage else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
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

    @discardableResult
    func applyAlignmentIfNeeded(to textView: CellTextView, alignment: NSTextAlignment) -> Bool {
        guard let cell = textView.modelCell, lastAppliedAlignment[cell] != alignment else { return false }
        applyAlignment(to: textView, alignment: alignment)
        return true
    }

    // MARK: - NSTextViewDelegate (shared across all pooled cells)

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
        // Guard the echo: this programmatic swap fires selectionDidChange,
        // and publishing it mid-view-update is the "publishing from within
        // view updates" fault.
        applyingProgrammaticContent = true
        textView.selectedRanges = [NSValue(range: NSRange(location: loc, length: 0))]
        applyingProgrammaticContent = false
        // The guard swallows the echo that used to sync the model, so
        // report the collapse explicitly, off the update pass.
        let viewModel = self.viewModel
        DispatchQueue.main.async {
            viewModel.updateCellSelection(row: cell.row, col: cell.column, NSRange(location: loc, length: 0))
        }
    }
}

/// The cell's clipping container: a plain layer-backed view that pins its
/// editor to the slot and clips overflow. The per-cell NSScrollView wrapper
/// it replaces added a scroll view and clip view per cell — tiling,
/// tracking-area, and wheel machinery the display cycle walked every
/// toggle — only to be told never to scroll. The wheel now rides the
/// responder chain from the editor straight up to the grid's scroll view.
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

/// Move-handle glyphs, cached by tint and appearance: building a configured
/// SF Symbol inside draw() re-ran CoreSVG instantiation for every handle on
/// every grid redraw (the profile's biggest display cost). Main-thread only.
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

// Flipped so document coordinates match the view model's top-down layout.
// The whole sync happens in sync(): SwiftUI re-runs updateNSView whenever a
// property the grid reads changes, and drags animate through applyDragFrames.
final class GridDocumentView: NSView {
    weak var coordinator: GridCoordinator?
    override var isFlipped: Bool { true }

    private var geometry: GridGeometry? {
        guard let coordinator else { return nil }
        return GridGeometry(viewModel: coordinator.viewModel)
    }

    override func draw(_ dirtyRect: NSRect) {
        let geom = geometry
        // The padded container's separator tint shows through every 1pt gap;
        // the top-left corner box (and caption gutter) is control-colored.
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        if let geom {
            NSColor.separatorColor.setFill()
            NSRect(origin: .zero, size: geom.blockSize).fill()
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: geom.gridLeftEdge, height: geom.gridTopEdge).fill()
        }
    }

    @MainActor
    func sync() {
        guard let coordinator else { return }
        let viewModel = coordinator.viewModel
        let geom = GridGeometry(viewModel: viewModel)
        setFrameSize(geom.blockSize)
        needsDisplay = true

        let placements = viewModel.table.placements()
        let liveCells: Set<GridCell> = Set(placements.enumerated().flatMap { row, slots in
            slots.map { GridCell(row: row, column: $0.cellIndex) }
        })

        // Drop pooled editors whose cell vanished with the last table.
        for (cell, view) in coordinator.cellViews where !liveCells.contains(cell) {
            view.removeFromSuperview()
            coordinator.cellViews.removeValue(forKey: cell)
            coordinator.lastAppliedRevision[cell] = nil
            coordinator.lastAppliedAlignment[cell] = nil
            coordinator.lastFocused[cell] = nil
            if coordinator.spareCells.count < 48 { coordinator.spareCells.append(view) }
        }

        var liftedCells: [NSView] = []
        for (row, slots) in placements.enumerated() {
            for p in slots {
                let key = GridCell(row: row, column: p.cellIndex)
                guard let cell = viewModel.cell(row: row, col: p.cellIndex) else { continue }
                let scroll: NSView
                if let existing = coordinator.cellViews[key] {
                    scroll = existing
                } else {
                    scroll = makeCellContainer(key: key, coordinator: coordinator)
                    coordinator.cellViews[key] = scroll
                    addSubview(scroll)
                }
                let slotRect = geom.cellRect(row: row, placement: p, coordinator: coordinator)
                if scroll.frame != slotRect { scroll.frame = slotRect }
                guard let textView = scroll.subviews.first as? CellTextView else { continue }
                textView.modelCell = key
                textView.modelStartCol = p.startCol
                textView.gridVisualOrigin = VisualCell(row: row, column: p.startCol)
                textView.gridVisualSpan = p.colSpan
                textView.gridVisualRowSpan = p.rowSpan
                textView.visualCellAt = { [weak viewModel] point in
                    guard let viewModel else { return nil }
                    let geom = GridGeometry(viewModel: viewModel)
                    return WYSIWYGView.visualCell(at: point,
                                                  columnWidths: viewModel.columnWidths,
                                                  rowHeights: viewModel.rowHeights,
                                                  captionOffset: geom.captionBandHeight)
                }
                let background = NSTextViewRepresentable.background(isHeader: cell.isHeader)
                let bgChanged = !textView.backgroundColor.isEqual(background)
                if bgChanged { textView.backgroundColor = background }
                let wrote = coordinator.apply(content: cell.content, revision: viewModel.contentRevision,
                                              to: textView, alignment: cell.alignment)
                // Per-cell focus border (was CellView's strokeBorder overlay).
                let focused = viewModel.focusedCell == key
                let borderW: CGFloat = focused ? 2 : 1
                let borderC: NSColor = focused ? .controlAccentColor : .separatorColor
                let borderChanged = textView.gridBorderWidth != borderW
                    || !(textView.gridBorderColor?.isEqual(borderC) ?? false)
                textView.gridBorderColor = borderC
                textView.gridBorderWidth = borderW
                let lifted = isLifted(row: row, startCol: p.startCol, coordinator: coordinator)
                scroll.alphaValue = coordinator.columnDrag.dragged == p.startCol ? 0.5 : 1
                // Only a real change dirties the editor: forcing needsDisplay
                // on every cell every sync redrew the whole grid per switch
                // and forced synchronous glyph layout via the dirty-rect math.
                if wrote || borderChanged || bgChanged { textView.needsDisplay = true }
                if lifted { liftedCells.append(scroll) }

                // Focus bridge: follow false→true grid moves only when the
                // keyboard is already in the grid; initial creation (nil→true)
                // must not steal focus, preserving the click-to-edit contract.
                let wasFocused = coordinator.lastFocused[key]
                coordinator.lastFocused[key] = focused
                if focused, wasFocused == false,
                   window?.firstResponder is CellTextView, window?.firstResponder !== textView {
                    DispatchQueue.main.async { [weak self, weak textView] in
                        guard let self, let textView,
                              self.window?.firstResponder is CellTextView,
                              self.window?.firstResponder !== textView else { return }
                        self.window?.makeFirstResponder(textView)
                    }
                }
            }
        }
        liftedCells.forEach { addSubview($0) }

        syncCaption(geom: geom, viewModel: viewModel, coordinator: coordinator)
        syncRowStrips(geom: geom, coordinator: coordinator)
        syncColumnStrips(geom: geom, coordinator: coordinator)
        syncResizeHandles(geom: geom, viewModel: viewModel, coordinator: coordinator)
        syncGapHighlights(geom: geom, coordinator: coordinator)
        syncSelectionBorder(geom: geom, viewModel: viewModel, coordinator: coordinator)
        restoreStackingOrder()
    }

    /// Builds the pooled per-cell container: a plain clipping view whose one
    /// subview is the editor, pinning the clip width and the slot height;
    /// the wheel rides the responder chain up to the grid's scroll view.
    @MainActor
    private func makeCellContainer(key: GridCell, coordinator: GridCoordinator) -> NSView {
        // A stashed editor re-points as-is: sync resets the modelCell and
        // spans, apply() re-checks content, and stale revisions were cleared
        // when the view was dropped.
        if let spare = coordinator.spareCells.popLast(),
           let editor = spare.subviews.first as? CellTextView {
            editor.selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
            return spare
        }
        // Explicit TextKit 1 stack at creation: touching .layoutManager on a
        // default (TextKit 2) view switches layout systems mid-setup and the
        // layer-backed view then renders blank. Temporary attributes need TK1.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = CellTextView(frame: .zero, textContainer: container)
        textView.delegate = coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        // Undo is owned by the shared editor manager, not the text view.
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .controlBackgroundColor
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
        // The container sizes the editor; autoresizing would fight it.
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        wireCell(textView, coordinator: coordinator)
        let clip = GridCellClipView()
        clip.addSubview(textView)
        return clip
    }

    /// Handlers read `modelCell` at fire time, so a pooled view that lands on
    /// a different cell after a table switch keeps reporting the right one.
    private func wireCell(_ textView: CellTextView, coordinator: GridCoordinator) {
        let viewModel = coordinator.viewModel
        textView.undoManagerOverride = viewModel.undoManager
        textView.didBecomeFirstResponderHandler = { [weak textView, weak viewModel] in
            guard let cell = textView?.modelCell else { return }
            viewModel?.focusedCell = cell
        }
        textView.flushPendingEditsHandler = { [weak viewModel] in
            viewModel?.closeTypingGroup()
        }
        textView.keyCommandHandler = { [weak textView, weak viewModel] event in
            guard let cell = textView?.modelCell else { return false }
            return viewModel?.handleGridKey(event, from: cell) ?? false
        }
        textView.cellCommandHandler = { [weak textView, weak viewModel] command in
            guard let cell = textView?.modelCell else { return }
            switch command {
            case .addRowAbove: viewModel?.addRow(adjacentTo: cell, after: false)
            case .addRowBelow: viewModel?.addRow(adjacentTo: cell, after: true)
            case .addColumnLeft: viewModel?.addColumn(adjacentTo: cell, after: false)
            case .addColumnRight: viewModel?.addColumn(adjacentTo: cell, after: true)
            case .duplicateRow: viewModel?.duplicateRow(adjacentTo: cell, after: true)
            case .duplicateColumn: viewModel?.duplicateColumn(adjacentTo: cell, after: true)
            }
        }
        textView.cellCommandValidator = { [weak textView, weak viewModel] command in
            guard let cell = textView?.modelCell else { return true }
            switch command {
            case .duplicateRow: return viewModel?.canDuplicateRow(cell.row) ?? true
            case .duplicateColumn: return viewModel?.canDuplicateColumn(textView?.modelStartCol ?? cell.column) ?? true
            default: return true
            }
        }
        textView.cellRangeHandler = { [weak viewModel] range in
            viewModel?.cellSelection = range
        }
        textView.copyCellsHandler = { [weak viewModel] in
            viewModel?.copySelectedCells() ?? false
        }
        textView.pasteTableHandler = { [weak viewModel] in
            viewModel?.pasteTableFromPasteboardIfTable() ?? false
        }
        textView.colspanCurrent = { [weak textView, weak viewModel] in
            guard let cell = textView?.modelCell else { return 1 }
            return viewModel?.cell(row: cell.row, col: cell.column)?.colspan ?? 1
        }
        textView.colspanSet = { [weak textView, weak viewModel] span in
            guard let cell = textView?.modelCell else { return }
            viewModel?.setColspan(span, for: cell)
        }
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
            view.frame = NSRect(x: WYSIWYGView.divider,
                                y: WYSIWYGView.slotTop(source: source, target: target, rowHeights: viewModel.rowHeights)
                                    + WYSIWYGView.columnGutterHeight + WYSIWYGView.divider + geom.captionBandHeight,
                                width: WYSIWYGView.gutterWidth + WYSIWYGView.divider + geom.gridColumnsWidth,
                                height: geom.rowHeight(source) + WYSIWYGView.divider)
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
            view.frame = NSRect(x: geom.gridLeftEdge - WYSIWYGView.divider
                                    + WYSIWYGView.slotLeft(source: source, target: target, widths: viewModel.columnWidths),
                                y: WYSIWYGView.divider,
                                width: geom.columnWidth(source) + WYSIWYGView.divider,
                                height: WYSIWYGView.columnGutterHeight + geom.captionBandHeight + geom.gridHeight)
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

    /// Keeps the z-order the SwiftUI tree implied: cells (lifted last), then
    /// strips/handles, then highlights, then the selection border on top.
    /// Re-adding an existing subview moves it to the front.
    private func restoreStackingOrder() {
        guard let coordinator else { return }
        for (_, strip) in coordinator.rowStrips { addSubview(strip) }
        for (_, strip) in coordinator.columnStrips { addSubview(strip) }
        for (_, handle) in coordinator.rowResizeHandles { addSubview(handle) }
        for (_, handle) in coordinator.columnResizeHandles { addSubview(handle) }
        if let field = coordinator.captionField { addSubview(field) }
        if let gap = coordinator.rowGapHighlight { addSubview(gap) }
        if let gap = coordinator.columnGapHighlight { addSubview(gap) }
        if let border = coordinator.selectionBorder { addSubview(border) }
    }

    private func isLifted(row: Int, startCol: Int, coordinator: GridCoordinator) -> Bool {
        if coordinator.rowDrag.dragged == row { return true }
        if coordinator.rowDrag.settleSlot == row && abs(coordinator.rowDrag.settleOffset) > 0.5 { return true }
        if coordinator.columnDrag.dragged == startCol { return true }
        if coordinator.columnDrag.settleSlot == startCol && abs(coordinator.columnDrag.settleOffset) > 0.5 { return true }
        return false
    }

    // MARK: - Drag frame application (called by the handle views)

    @MainActor
    func applyRowDragFrames(animated: Bool, coordinator: GridCoordinator) {
        guard let geom = geometry else { return }
        let rowCount = coordinator.viewModel.table.rows.count
        for row in 0..<rowCount {
            let offset = geom.rowOffset(row, coordinator: coordinator)
            let changed = coordinator.appliedRowOffsets[row] != offset
            coordinator.appliedRowOffsets[row] = offset
            guard changed else { continue }
            if let strip = coordinator.rowStrips[row] {
                let f = strip.frame
                let base = geom.gridTopEdge + geom.localRowTop(row)
                animate(strip, fromY: f.origin.y, toY: base + offset, animated: animated)
            }
            for (cell, view) in coordinator.cellViews where cell.row == row {
                let f = view.frame
                let baseY = geom.gridTopEdge + geom.localRowTop(row)
                animate(view, fromY: f.origin.y, toY: baseY + offset, animated: animated)
            }
        }
        syncGapHighlights(geom: geom, coordinator: coordinator)
        needsDisplay = true
    }

    @MainActor
    func applyColumnDragFrames(animated: Bool, coordinator: GridCoordinator) {
        guard let geom = geometry else { return }
        let colCount = coordinator.viewModel.columnWidths.count
        for col in 0..<colCount {
            let shift = geom.columnShift(col, coordinator: coordinator)
            let changed = coordinator.appliedColumnOffsets[col] != shift
            coordinator.appliedColumnOffsets[col] = shift
            guard changed else { continue }
            if let strip = coordinator.columnStrips[col] {
                let f = strip.frame
                let base = geom.gridLeftEdge + geom.localColumnLeft(col)
                animate(strip, fromX: f.origin.x, toX: base + shift, animated: animated)
            }
            for (_, scroll) in coordinator.cellViews where (scroll.subviews.first as? CellTextView)?.gridVisualOrigin?.column == col {
                let f = scroll.frame
                let baseX = geom.gridLeftEdge + geom.localColumnLeft(col)
                animate(scroll, fromX: f.origin.x, toX: baseX + shift, animated: animated)
                scroll.alphaValue = coordinator.columnDrag.dragged == col ? 0.5 : 1
            }
        }
        syncGapHighlights(geom: geom, coordinator: coordinator)
        needsDisplay = true
    }

    private var viewModel: TableViewModel? { coordinator?.viewModel }

    private func animate(_ view: NSView, fromX: CGFloat = 0, toX: CGFloat? = nil,
                         fromY: CGFloat = 0, toY: CGFloat? = nil, animated: Bool) {
        var origin = view.frame.origin
        if let toX { origin.x = toX }
        if let toY { origin.y = toY }
        guard animated else {
            view.setFrameOrigin(origin)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.allowsImplicitAnimation = true
            view.animator().setFrameOrigin(origin)
        }
    }

    override func resetCursorRects() {
        // The handle views own their cursor rects; nothing to add here.
    }
}

@MainActor
extension GridCoordinator {
    @objc func captionChanged(_ sender: NSTextField) {
        parent?.viewModel.captionBinding.wrappedValue = sender.stringValue
    }
}

// MARK: - Overlay views

final class GapHighlightView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    }
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
}

// MARK: - Move handles (gutter strips)

/// Shared mouse-drag plumbing: a local event monitor turns screen-space
/// movement into the signed translation the old DragGesture delivered
/// (down/right positive), with the gesture's minimumDistance honored.
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
        let geom = GridGeometry(viewModel: coordinator.viewModel)
        monitor = GridDragGesture.start(event: event, minimumDistance: 3, axisIsVertical: true,
            onChanged: { [weak self, weak coordinator, weak documentView] translation, first in
                guard let coordinator, let documentView else { return }
                if first {
                    snapshot = coordinator.viewModel.currentSnapshot()
                    coordinator.rowDrag.settleSlot = nil
                    coordinator.rowDrag.settleOffset = 0
                    coordinator.rowDrag.reset()
                    coordinator.rowDrag.dragged = self?.row
                    coordinator.rowDrag.target = self?.row
                    coordinator.appliedRowOffsets.removeAll()
                }
                coordinator.rowDrag.translation = translation
                let landing = Self.landingIndex(translation: translation, index: self?.row ?? 0,
                                                count: coordinator.viewModel.table.rows.count,
                                                sizes: coordinator.viewModel.rowHeights,
                                                fallback: TableViewModel.defaultRowHeight)
                let animated = coordinator.rowDrag.target != landing
                coordinator.rowDrag.target = landing
                documentView.applyRowDragFrames(animated: animated, coordinator: coordinator)
            },
            onEnded: { [weak self, weak coordinator, weak documentView] translation in
                guard let self, let coordinator, let documentView else { return }
                defer { coordinator.rowDrag.reset(); coordinator.appliedRowOffsets.removeAll(); documentView.sync() }
                guard let before = snapshot, translation != 0 else { return }
                let dest = Self.landingIndex(translation: translation, index: self.row,
                                             count: coordinator.viewModel.table.rows.count,
                                             sizes: coordinator.viewModel.rowHeights,
                                             fallback: TableViewModel.defaultRowHeight)
                let source = self.row
                // The row's current visual top, per rowOffset's math.
                let gap = WYSIWYGView.slotTop(source: source, target: dest, rowHeights: coordinator.viewModel.rowHeights)
                let slack = min(max(geom.rowTop(source) + translation - gap, -WYSIWYGView.followSlack), WYSIWYGView.followSlack)
                let visualTop = gap + slack
                coordinator.viewModel.moveRow(from: source, to: dest, before: before)
                // The commit relays rows instantly; pin the row at its visual
                // position, then spring it to its new slot. The new slot's top
                // must come from the post-move heights, so re-read geometry.
                let moved = GridGeometry(viewModel: coordinator.viewModel)
                coordinator.rowDrag.settleSlot = dest
                coordinator.rowDrag.settleOffset = visualTop - moved.rowTop(dest)
                coordinator.appliedRowOffsets.removeAll()
                documentView.sync()
                Self.settleRow(to: 0, coordinator: coordinator, documentView: documentView)
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
        let geom = GridGeometry(viewModel: coordinator.viewModel)
        monitor = GridDragGesture.start(event: event, minimumDistance: 3, axisIsVertical: false,
            onChanged: { [weak self, weak coordinator, weak documentView] translation, first in
                guard let coordinator, let documentView else { return }
                if first {
                    snapshot = coordinator.viewModel.currentSnapshot()
                    coordinator.columnDrag.settleSlot = nil
                    coordinator.columnDrag.settleOffset = 0
                    coordinator.columnDrag.reset()
                    coordinator.columnDrag.dragged = self?.col
                    coordinator.columnDrag.target = self?.col
                    coordinator.appliedColumnOffsets.removeAll()
                }
                coordinator.columnDrag.translation = translation
                let landing = Self.landingIndex(translation: translation, index: self?.col ?? 0,
                                                count: coordinator.viewModel.columnWidths.count,
                                                sizes: coordinator.viewModel.columnWidths,
                                                fallback: TableViewModel.defaultColumnWidth)
                let animated = coordinator.columnDrag.target != landing
                coordinator.columnDrag.target = landing
                documentView.applyColumnDragFrames(animated: animated, coordinator: coordinator)
            },
            onEnded: { [weak self, weak coordinator, weak documentView] translation in
                guard let self, let coordinator, let documentView else { return }
                defer { coordinator.columnDrag.reset(); coordinator.appliedColumnOffsets.removeAll(); documentView.sync() }
                guard let before = snapshot, translation != 0 else { return }
                let dest = Self.landingIndex(translation: translation, index: self.col,
                                             count: coordinator.viewModel.columnWidths.count,
                                             sizes: coordinator.viewModel.columnWidths,
                                             fallback: TableViewModel.defaultColumnWidth)
                let source = self.col
                // The column's current visual left, per columnShift's math.
                let gap = WYSIWYGView.slotLeft(source: source, target: dest, widths: coordinator.viewModel.columnWidths)
                let slack = min(max(geom.columnLeft(source) + translation - gap, -WYSIWYGView.followSlack), WYSIWYGView.followSlack)
                let visualLeft = gap + slack
                coordinator.viewModel.moveColumn(from: source, to: dest, before: before)
                let moved = GridGeometry(viewModel: coordinator.viewModel)
                coordinator.columnDrag.settleSlot = dest
                coordinator.columnDrag.settleOffset = visualLeft - moved.columnLeft(dest)
                coordinator.appliedColumnOffsets.removeAll()
                documentView.sync()
                Self.settleColumn(to: 0, coordinator: coordinator, documentView: documentView)
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

// MARK: - Landing index (ported verbatim from the SwiftUI handles)

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

    /// Springs the settling row's views to `offset` and clears the settle pin.
    static func settleRow(to offset: CGFloat, coordinator: GridCoordinator, documentView: GridDocumentView) {
        guard coordinator.rowDrag.settleSlot != nil else { return }
        DispatchQueue.main.async {
            coordinator.rowDrag.settleOffset = offset
            coordinator.appliedRowOffsets.removeAll()
            documentView.sync()
            documentView.applyRowDragFrames(animated: true, coordinator: coordinator)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                coordinator.rowDrag.settleSlot = nil
                coordinator.rowDrag.settleOffset = 0
                documentView.sync()
            }
        }
    }
}

extension ColumnMoveHandleView {
    /// Landing column for a drop at `translation`: count column centers left
    /// of the drag point; dragging right past the column's own center reserves
    /// the slot on the right.
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

    static func settleColumn(to offset: CGFloat, coordinator: GridCoordinator, documentView: GridDocumentView) {
        guard coordinator.columnDrag.settleSlot != nil else { return }
        DispatchQueue.main.async {
            coordinator.columnDrag.settleOffset = offset
            coordinator.appliedColumnOffsets.removeAll()
            documentView.sync()
            documentView.applyColumnDragFrames(animated: true, coordinator: coordinator)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                coordinator.columnDrag.settleSlot = nil
                coordinator.columnDrag.settleOffset = 0
                documentView.sync()
            }
        }
    }
}

// MARK: - Geometry

/// The layout math the SwiftUI WYSIWYGView carried, in padded-container
/// document coordinates. Every constant here is pinned by the gridlayout,
/// rowbound, and handlepos probes.
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

    /// Top edge of a row in pre-shift layout coordinates.
    func rowTop(_ row: Int) -> CGFloat {
        guard row > 0, row < rowHeights.count else { return divider }
        return divider + rowHeights[0..<row].reduce(0, +) + CGFloat(row) * divider
    }

    /// Left edge of a column in pre-shift layout coordinates.
    func columnLeft(_ col: Int) -> CGFloat {
        guard col > 0, col < columnWidths.count else { return divider }
        return divider + columnWidths[0..<col].reduce(0, +) + CGFloat(col) * divider
    }

    /// Height of a cell that towers over `rowSpan` rows, dividers included.
    func cellHeight(row: Int, rowSpan: Int) -> CGFloat {
        // @Observable partial invalidation can re-run a removed slot's content
        // closure with its captured row index against the new table's heights,
        // so bound it like the other index-keyed reads here.
        guard row < rowHeights.count else { return TableViewModel.defaultRowHeight }
        var height = CGFloat(max(rowSpan - 1, 0)) * divider
        for spanned in row..<min(row + rowSpan, rowHeights.count) {
            height += rowHeight(spanned)
        }
        return height
    }

    // Rows between source and landing slot slide aside; the grabbed row
    // rides the opened gap, rubber-banded to the cursor.
    func rowOffset(_ row: Int, coordinator: GridCoordinator) -> CGFloat {
        let drag = coordinator.rowDrag
        if drag.dragged == row {
            let target = drag.target ?? row
            let gap = WYSIWYGView.slotTop(source: row, target: target, rowHeights: rowHeights)
            let desired = rowTop(row) + drag.translation
            let slack = min(max(desired - gap, -WYSIWYGView.followSlack), WYSIWYGView.followSlack)
            return gap + slack - rowTop(row)
        }
        if drag.settleSlot == row { return drag.settleOffset }
        guard let source = drag.dragged, let target = drag.target, target != source else { return 0 }
        let step = rowHeight(source) + divider
        if target > source, row > source, row <= target { return -step }
        if target < source, row >= target, row < source { return step }
        return 0
    }

    func columnShift(_ col: Int, coordinator: GridCoordinator) -> CGFloat {
        let drag = coordinator.columnDrag
        if drag.dragged == col {
            let target = drag.target ?? col
            let gap = WYSIWYGView.slotLeft(source: col, target: target, widths: columnWidths)
            let desired = columnLeft(col) + drag.translation
            let slack = min(max(desired - gap, -WYSIWYGView.followSlack), WYSIWYGView.followSlack)
            return gap + slack - columnLeft(col)
        }
        if drag.settleSlot == col { return drag.settleOffset }
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
        for (row, slots) in viewModel.table.placements().enumerated() {
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
