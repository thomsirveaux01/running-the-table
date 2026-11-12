import AppKit
import Combine
import SwiftUI

struct GridCell: Hashable {
    var row: Int
    var column: Int
}

/// Layout-space cell coordinates: columns are the grid's visual columns, so
/// a colspan cell covers several, unlike array-indexed GridCell.
struct VisualCell: Equatable {
    var row: Int
    var column: Int
}

/// A closed rectangle of visual cells — the drag selection's range.
struct VisualCellRange: Equatable {
    var rowStart: Int
    var rowEnd: Int
    var colStart: Int
    var colEnd: Int

    /// True when a slot, which may span several columns and rows, intersects
    /// the range.
    func intersects(row: Int, rowSpan: Int = 1, startCol: Int, span: Int) -> Bool {
        row <= rowEnd && row + rowSpan - 1 >= rowStart
            && startCol <= colEnd && startCol + span - 1 >= colStart
    }
}

/// Full editor state captured to revert one undo step. The whole Table (not
/// just rows) rides along so captions, sections and pass-through markup undo
/// with the cells around them.
struct EditorSnapshot {
    let documentID: UUID?
    let table: Table
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
    let focusedCell: GridCell?
}

// Deliberately flat: nested ObservableObjects crash observation tracking.
@MainActor
final class TableViewModel: ObservableObject {
    @Published var documents: [TableDocument]
    @Published var selectedDocumentID: UUID?
    /// The sidebar's ⌘-click set; the editor follows its last-clicked table.
    @Published var sidebarSelection: Set<UUID> = []
    @Published var table: Table
    // Text views re-apply content only on revision bumps, so a stale render
    // can't revert text the user just typed.
    @Published private(set) var contentRevision = 0

    @Published var htmlText: String = ""
    @Published var focusedCell: GridCell? {
        didSet {
            guard focusedCell != oldValue else { return }
            // Typing runs end when focus moves to another cell.
            closeTypingGroup()
            if let f = focusedCell, let c = cell(row: f.row, col: f.column) {
                selectionRange = c.selectionRange
            } else {
                selectionRange = NSRange(location: 0, length: 0)
            }
        }
    }
    // Plain var, not @Published: nothing observes it, and publishing it from
    // focusedCell's didSet during a view update trips SwiftUI's "publishing
    // from within view updates" fault.
    var selectionRange = NSRange(location: 0, length: 0)
    /// Rectangular drag selection in visual coordinates; nil when none.
    @Published var cellSelection: VisualCellRange?
    @Published var columnWidths: [CGFloat] = []
    @Published var rowHeights: [CGFloat] = []
    @Published var showLinkPrompt = false
    @Published var linkURLText = ""
    /// True while a text view owns the caret; the ⌘⌫ delete-table chord disables
    /// itself so the keystroke stays a text-editing command.
    @Published private(set) var isEditingText = false

    /// Table snapshots offered by New from Template. They live in a subfolder,
    /// so loadStoredDocuments never lists them as tables.
    @Published private(set) var templates: [TableDocument] = []
    @Published var showTemplatePrompt = false
    @Published var templateNameText = ""
    @Published var showTemplateManager = false
    @Published var showRenamePrompt = false
    @Published var renameTitleText = ""
    /// The filename the rename sheet displays, derived live from the title.
    var renameFileNameDisplay: String {
        Self.sanitizedFileName(renameTitleText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// Notes on dropped or unclosed markup in the latest source-pane parse;
    /// empty whenever the grid generated the HTML.
    @Published private(set) var markupDiagnostics: [String] = []
    private var renamingID: UUID?
    private var templateDraftTable: Table?

    // Prevents recursive WYSIWYG/HTML pane updates during sync.
    var isUpdating = false

    static let defaultColumnWidth: CGFloat = 140
    static let defaultRowHeight: CGFloat = 32
    static let minColumnWidth: CGFloat = 40
    static let minRowHeight: CGFloat = 24

    init() {
        // One-time title-store migration. With a stored grant the library
        // isn't reachable yet (the container is), so it runs in
        // reloadFromDisk once launchOnce resolves the grant instead.
        if LibraryLocation.defaults.data(forKey: LibraryLocation.bookmarkKey) == nil {
            Self.migrateTitleStoreIfNeeded()
        }
        documents = Self.loadStoredDocuments()
        templates = Self.loadStoredTemplates()
        selectedDocumentID = nil
        table = Table.new()
        focusedCell = nil
        ensureSizing()
        regenerateHTML()
        for doc in documents {
            if let url = doc.fileURL, let html = try? String(contentsOf: url, encoding: .utf8) {
                savedHTML[doc.id] = html
            }
        }
        // Manual grouping: one undo reverts one logical change regardless of
        // how many registrations happen in a single run-loop pass.
        undoManager.groupsByEvent = false
        // The Task hop runs the sink after the mutation has settled.
        autosaveObserver = objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleAutosave() }
        }
        // Quitting mid-debounce must not lose the last edits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushAndSaveAll() }
        }
        // AppKit posts no first-responder notification, so re-read it on the
        // window update pass; a stale value can only refuse to delete.
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let editing = Self.caretInTextView(NSApp.keyWindow)
                    if self?.isEditingText != editing { self?.isEditingText = editing }
                }
            }
        }
        // The migration (above) already aligned filenames with names, so on a
        // fresh launch every write is a cache hit and this is a no-op.
        saveAllDocuments()
    }

    /// Re-read tables and templates after the library root moves underneath
    /// the running app (Settings change or container fallback).
    func reloadFromDisk() {
        flushToDocument()
        // The grant is resolved by the time this runs, so the library is
        // reachable and the one-time title-store migration is safe here.
        Self.migrateTitleStoreIfNeeded()
        documents = Self.loadStoredDocuments()
        templates = Self.loadStoredTemplates()
        selectedDocumentID = nil
        sidebarSelection = []
        table = Table.new()
        focusedCell = nil
        ensureSizing()
        regenerateHTML()
        savedHTML.removeAll()
        for doc in documents {
            if let url = doc.fileURL, let html = try? String(contentsOf: url, encoding: .utf8) {
                savedHTML[doc.id] = html
            }
        }
    }

    // Shared stack: cells and the HTML pane return this from their
    // undoManager override, so every edit shares one history.
    let undoManager = UndoManager()

    // Consecutive edits to the same key coalesce into one undo step; the run
    // closes on focus move, another action, or idle timeout.
    private struct PendingTyping {
        let key: GridCell
        let name: String
        let before: EditorSnapshot
    }

    private var pendingTyping: PendingTyping?
    private var typingTimer: Timer?

    // Sentinel key for the HTML source pane's typing run.
    static let htmlEditorKey = GridCell(row: -1, column: -1)
    static let typingCoalesceInterval: TimeInterval = 1.0

    // Captures state around a mutation and records one undo/redo pair.
    func performUndoable(_ name: String, _ mutate: () -> Void) {
        closeTypingGroup()
        let before = currentSnapshot()
        mutate()
        contentRevision += 1
        let after = currentSnapshot()
        registerSnapshotUndo(name: name, undoTo: before, redoTo: after)
    }

    func registerSnapshotUndo(name: String, undoTo: EditorSnapshot, redoTo: EditorSnapshot) {
        // With groupsByEvent off, Foundation requires explicit undo groups.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            // Register the redo pair before reverting.
            target.registerSnapshotUndo(name: name, undoTo: redoTo, redoTo: undoTo)
            target.restore(undoTo)
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    // Whole resize drags register once, on drag end.
    func registerResizeUndo(name: String, before: EditorSnapshot) {
        closeTypingGroup()
        registerSnapshotUndo(name: name, undoTo: before, redoTo: currentSnapshot())
    }

    // Menu undo/redo when no cell view has focus: close the open typing run
    // first so the menu reverts whole runs like the in-cell path.
    func undoFromMenu() {
        closeTypingGroup()
        undoManager.undo()
    }

    func redoFromMenu() {
        closeTypingGroup()
        undoManager.redo()
    }

    // Extend or open a typing run for a cell or the HTML pane.
    private func appendTypingChange(key: GridCell, name: String, before: EditorSnapshot) {
        if let pending = pendingTyping, pending.key == key, pending.name == name {
            // Keep the earliest snapshot so one undo reverts the whole run.
            restartTypingTimer()
            return
        }
        closeTypingGroup()
        pendingTyping = PendingTyping(key: key, name: name, before: before)
        restartTypingTimer()
    }

    // Commit the open typing run as one undo step.
    func closeTypingGroup() {
        typingTimer?.invalidate()
        typingTimer = nil
        guard let pending = pendingTyping else { return }
        pendingTyping = nil
        let after = currentSnapshot()
        registerSnapshotUndo(name: pending.name, undoTo: pending.before, redoTo: after)
    }

    private func restartTypingTimer() {
        typingTimer?.invalidate()
        // The view model lives for the whole session, so the one-shot timer
        // may hold it strongly; invalidate() breaks the wait anyway.
        typingTimer = Timer.scheduledTimer(withTimeInterval: Self.typingCoalesceInterval, repeats: false) { _ in
            Task { @MainActor in self.closeTypingGroup() }
        }
    }

    func currentSnapshot() -> EditorSnapshot {
        EditorSnapshot(documentID: selectedDocumentID,
                       table: table.deepCopied(),
                       columnWidths: columnWidths,
                       rowHeights: rowHeights,
                       focusedCell: focusedCell)
    }

    private func restore(_ snapshot: EditorSnapshot) {
        // The snapshot may belong to another still-open table.
        if let docID = snapshot.documentID, docID != selectedDocumentID {
            guard let doc = documents.first(where: { $0.id == docID }) else { return }
            selectedDocumentID = docID
            sidebarSelection = [docID]
            table = doc.table
        }
        var restored = snapshot.table.deepCopied()
        // The title is document state with its own undo path; row edits must
        // not resurrect an old name.
        restored.name = table.name
        table = restored
        columnWidths = snapshot.columnWidths
        rowHeights = snapshot.rowHeights
        ensureSizing()
        focusedCell = snapshot.focusedCell
        keepFocusValid()
        flushToDocument()
        regenerateHTML()
        contentRevision += 1
    }

    // Later edits must never mutate state captured in a snapshot.
    private func deepCopied(_ documents: [TableDocument]) -> [TableDocument] {
        documents.map { doc in
            var copy = doc
            copy.table = doc.table.deepCopied()
            return copy
        }
    }

    func document(id: UUID?) -> TableDocument? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    var currentDocumentIndex: Int? {
        documents.firstIndex { $0.id == selectedDocumentID }
    }

    // Bounds-safe: SwiftUI bindings may be stale while the table mutates.
    func cell(row: Int, col: Int) -> TableCell? {
        guard table.isValid(row: row, col: col) else { return nil }
        return table.rows[row][col]
    }

    func updateCellContent(row: Int, col: Int, _ content: NSAttributedString) {
        guard let existing = cell(row: row, col: col), !existing.content.isEqual(to: content) else { return }
        let before = currentSnapshot()
        table.rows[row][col].content = content
        // The parsed verbatim interior is now stale; content is the source
        // of truth from here on.
        table.rows[row][col].rawInnerHTML = nil
        clampSelection(inRow: row, col: col)
        // Wrapped text that outgrew the row pushes its height up (grow-only).
        growRowIfNeeded(row)
        flushToDocument()
        regenerateHTML()
        contentRevision += 1
        appendTypingChange(key: GridCell(row: row, column: col), name: "Edit Text", before: before)
    }

    func updateCellSelection(row: Int, col: Int, _ range: NSRange) {
        guard var c = cell(row: row, col: col) else { return }
        c.selectionRange = range
        table.rows[row][col] = c
        if focusedCell == GridCell(row: row, column: col) {
            selectionRange = range
        }
    }

    private func clampSelection(inRow row: Int, col: Int) {
        guard var c = cell(row: row, col: col) else { return }
        let clamped = NSIntersectionRange(c.selectionRange, c.fullRange)
        if clamped != c.selectionRange {
            c.selectionRange = clamped
            table.rows[row][col] = c
        }
        if focusedCell == GridCell(row: row, column: col) {
            selectionRange = clamped
        }
    }

    // Hardware keycodes: Tab/Return/Escape arrive as keyDown before the text
    // system can turn them into inserted characters.
    private static let tabKeyCode: UInt16 = 48
    private static let returnKeyCode: UInt16 = 36
    private static let keypadReturnKeyCode: UInt16 = 76
    private static let escapeKeyCode: UInt16 = 53
    private static let deleteKeyCode: UInt16 = 51

    // Unmodified Tab walks the grid, Return walks down a column, Escape
    // commits; everything else (Cmd+C, typing) passes through.
    func handleGridKey(_ event: NSEvent, from cell: GridCell) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case Self.tabKeyCode:
            moveFocus(from: cell, horizontal: shift ? -1 : 1)
            return true
        case Self.returnKeyCode, Self.keypadReturnKeyCode:
            moveFocus(from: cell, vertical: shift ? -1 : 1)
            return true
        case Self.escapeKeyCode:
            closeTypingGroup()
            cellSelection = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
            return true
        case Self.deleteKeyCode:
            // A cell block deletes as a block; without one, text editing rules.
            return clearSelectedCells()
        default:
            return false
        }
    }

    // Tab wraps past the row end into the next row (Shift reverses); Return
    // stays in the column, clamped at the grid edges.
    func moveFocus(from cell: GridCell, horizontal: Int = 0, vertical: Int = 0) {
        guard !table.rows.isEmpty else { return }
        cellSelection = nil
        var row = min(max(cell.row, 0), table.rows.count - 1)
        var col = min(max(cell.column, 0), max(table.rows[row].count - 1, 0))
        if horizontal != 0 {
            col += horizontal
            if col < 0 {
                if row > 0 {
                    row -= 1
                    col = table.rows[row].count - 1
                } else {
                    col = 0
                }
            } else if col >= table.rows[row].count {
                if row < table.rows.count - 1 {
                    row += 1
                    col = 0
                } else {
                    col = table.rows[row].count - 1
                }
            }
        }
        if vertical != 0 {
            row = min(max(row + vertical, 0), table.rows.count - 1)
            col = min(col, max(table.rows[row].count - 1, 0))
        }
        focusedCell = GridCell(row: row, column: col)
    }

    func regenerateHTML() {
        isUpdating = true
        // Generated markup is valid by construction; stale parse notes go.
        table.diagnostics = []
        markupDiagnostics = []
        htmlText = HTMLGenerator.html(for: table)
        isUpdating = false
    }

    // Keystrokes coalesce into one undo run, like typing in a cell.
    func importFromHTML(_ html: String) {
        guard !isUpdating, html != htmlText else { return }
        let before = currentSnapshot()
        isUpdating = true
        htmlText = html
        // A full re-parse: hand-typed captions, colgroups, attributes and
        // page markup around the table land in the model the same instant.
        table = Table.loaded(from: HTMLParser.parseTable(html), name: table.name, id: table.id)
        markupDiagnostics = table.diagnostics
        ensureSizing()
        refreshRowHeights()
        flushToDocument()
        isUpdating = false
        keepFocusValid()
        contentRevision += 1
        appendTypingChange(key: Self.htmlEditorKey, name: "Edit HTML", before: before)
    }

    private func flushToDocument() {
        guard let idx = currentDocumentIndex else { return }
        documents[idx].table = table
        documents[idx].columnWidths = columnWidths
        documents[idx].rowHeights = rowHeights
    }

    private func keepFocusValid() {
        guard let f = focusedCell else { return }
        let row = min(max(f.row, 0), max(table.rows.count - 1, 0))
        let col = table.rows.isEmpty ? 0 : min(max(f.column, 0), max(table.rows[row].count - 1, 0))
        focusedCell = GridCell(row: row, column: col)
    }

    func addRow() {
        guard let f = focusedCell else { return }
        addRow(adjacentTo: f, after: true)
    }

    /// Anchored on a cell rather than on focus: a context-menu command must act
    /// on the cell that was right-clicked, which is not the focused cell.
    func addRow(adjacentTo cell: GridCell, after: Bool) {
        guard cell.row < table.rows.count else { return }
        let index = cell.row + (after ? 1 : 0)
        performUndoable(after ? "Add Row" : "Add Row Above") {
            let cols = max(self.table.columnCount, 1)
            // Merges straddling the new boundary grow to cover the inserted
            // row; normalize then pads or trims the new row against the
            // resulting occupancy.
            for (origin, slots) in self.table.placements().enumerated() where origin < index {
                for p in slots where p.rowSpan > 1 && origin + p.rowSpan - 1 >= index {
                    self.table.rows[origin][p.cellIndex].rowspan =
                        min(p.rowSpan + 1, TableCell.maxRowspan)
                }
            }
            self.table.rows.insert(TableRow(cells: Array(repeating: TableCell(), count: cols)), at: index)
            self.table.normalize()
            self.ensureSizing()
            self.focusedCell = GridCell(row: index, column: cell.column)
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func addColumn() {
        guard let f = focusedCell else { return }
        addColumn(adjacentTo: f, after: true)
    }

    func addColumn(adjacentTo cell: GridCell, after: Bool) {
        guard let p = placement(of: cell) else { return }
        let boundary = p.startCol + (after ? p.colSpan : 0)
        performUndoable(after ? "Add Column" : "Add Column Left") {
            let slots = self.table.placements()
            // Merges the new column lands inside, by their origin rows.
            let straddlers = slots.enumerated().flatMap { row, rowSlots in
                rowSlots.filter { $0.startCol < boundary && boundary < $0.startCol + $0.colSpan }
                    .map { (row: row, placement: $0) }
            }
            for row in self.table.rows.indices {
                if let straddler = straddlers.first(where: {
                    row >= $0.row && row < $0.row + $0.placement.rowSpan
                }) {
                    // The new column belongs to the merge: the origin cell
                    // widens, and rows the merge covers get no cell of their
                    // own for it.
                    if row == straddler.row {
                        self.table.rows[row][straddler.placement.cellIndex].colspan =
                            min(straddler.placement.colSpan + 1, TableCell.maxColspan)
                    }
                    continue
                }
                // Array order matches visual order, so inserting before the
                // first own cell at or past the boundary (or appending) puts
                // the new cell in the new column even in rowspan-covered rows.
                let insertAt = slots[row].first { $0.startCol >= boundary }?.cellIndex
                    ?? self.table.rows[row].count
                // A row that is nothing but headers keeps its header-ness:
                // the new cell joins as a <th> so <thead> survives the add.
                self.table.rows[row].insert(TableCell(isHeader: self.table.rows[row].allHeaders), at: insertAt)
            }
            self.table.normalize()
            self.demoteNonHeaderRows()
            self.ensureSizing()
            let col = min(boundary, max(self.table.rows[cell.row].count - 1, 0))
            self.focusedCell = GridCell(row: cell.row, column: col)
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    /// The visual footprint of an array-indexed cell.
    private func placement(of cell: GridCell) -> Table.CellPlacement? {
        guard table.rows.indices.contains(cell.row),
              table.rows[cell.row].cells.indices.contains(cell.column) else { return nil }
        return table.placements()[cell.row].first { $0.cellIndex == cell.column }
    }

    func removeRow() {
        guard let f = focusedCell, table.rows.count > 1, f.row < table.rows.count,
              canRemoveRow(f.row) else { return }
        performUndoable("Remove Row") {
            self.table.rows.remove(at: f.row)
            self.table.normalize()
            self.ensureSizing()
            self.keepFocusValid()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    /// Deleting a row a merge touches would tear the merge; those rows stay
    /// undeletable until the merge is split.
    func canRemoveRow(_ row: Int) -> Bool {
        table.rows.indices.contains(row) && !table.rowspanCrosses(rows: row, row)
    }

    func removeColumn() {
        guard let f = focusedCell, table.columnCount > 1, let p = placement(of: f),
              !table.columnHasMerge(p.startCol) else { return }
        let col = p.startCol
        performUndoable("Remove Column") {
            for row in self.table.rows.indices {
                if let idx = self.cellIndex(containingColumn: col, in: self.table.rows[row]) {
                    self.table.rows[row].remove(at: idx)
                }
            }
            if self.columnWidths.indices.contains(col) { self.columnWidths.remove(at: col) }
            self.table.normalize()
            // The removal may leave a short row that normalize pads with a
            // plain <td>, costing a header row its all-<th> status.
            self.demoteNonHeaderRows()
            self.ensureSizing()
            self.keepFocusValid()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    /// A merge touching the column means wholesale removal would misalign the
    /// cells around it; those columns stay un-deletable until split.
    var canRemoveFocusedColumn: Bool {
        guard let f = focusedCell, table.columnCount > 1, let p = placement(of: f) else { return false }
        return !table.columnHasMerge(p.startCol)
    }

    // MARK: - Duplicate row/column

    /// A row a rowspan touches can't be copied: the duplicate would overlap the
    /// merge's covered rows, so those rows stay unduplicable until split (the
    /// same gate as removeRow).
    func canDuplicateRow(_ row: Int) -> Bool {
        table.rows.indices.contains(row) && !table.rowspanCrosses(rows: row, row)
    }

    var canDuplicateFocusedRow: Bool {
        guard let f = focusedCell else { return false }
        return canDuplicateRow(f.row)
    }

    /// Deep-copies the row and inserts the copy adjacent; fresh cells, so
    /// editing one never touches the other. The copy keeps the source's height
    /// and section (a <th> row duplicates as <th>).
    func duplicateRow(adjacentTo cell: GridCell, after: Bool) {
        guard canDuplicateRow(cell.row) else { return }
        let index = cell.row + (after ? 1 : 0)
        performUndoable(after ? "Duplicate Row" : "Duplicate Row Above") {
            self.table.rows.insert(self.table.rows[cell.row].deepCopy(), at: index)
            if self.rowHeights.indices.contains(cell.row) {
                self.rowHeights.insert(self.rowHeights[cell.row], at: index)
            }
            self.table.normalize()
            self.demoteNonHeaderRows()
            self.ensureSizing()
            self.growRowIfNeeded(index)
            self.focusedCell = GridCell(row: index, column: cell.column)
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func duplicateRow() {
        guard let f = focusedCell else { return }
        duplicateRow(adjacentTo: f, after: true)
    }

    /// A column any merge touches can't be copied: a colspan makes the copy
    /// ambiguous and a rowspan leaves covered rows with no cell to copy (the
    /// same gate as removeColumn).
    func canDuplicateColumn(_ col: Int) -> Bool {
        guard col >= 0, col < table.columnCount else { return false }
        return !table.columnHasMerge(col)
    }

    var canDuplicateFocusedColumn: Bool {
        guard let f = focusedCell, let p = placement(of: f) else { return false }
        return canDuplicateColumn(p.startCol)
    }

    /// Deep-copies each row's cell in the column and inserts the copies
    /// adjacent, so the new column carries the source's values, header status,
    /// and width.
    func duplicateColumn(adjacentTo cell: GridCell, after: Bool) {
        guard let p = placement(of: cell),
              let sourceIdx = cellIndex(containingColumn: p.startCol, in: table.rows[cell.row])
        else { return }
        let col = p.startCol
        guard canDuplicateColumn(col) else { return }
        performUndoable(after ? "Duplicate Column" : "Duplicate Column Left") {
            for row in self.table.rows.indices {
                guard let idx = self.cellIndex(containingColumn: col, in: self.table.rows[row]) else { continue }
                self.table.rows[row].insert(self.table.rows[row][idx].deepCopy(), at: after ? idx + 1 : idx)
            }
            if self.columnWidths.indices.contains(col) {
                self.columnWidths.insert(self.columnWidths[col], at: after ? col + 1 : col)
            }
            self.table.normalize()
            self.demoteNonHeaderRows()
            self.ensureSizing()
            self.focusedCell = GridCell(row: cell.row, column: after ? sourceIdx + 1 : sourceIdx)
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func duplicateColumn() {
        guard let f = focusedCell else { return }
        duplicateColumn(adjacentTo: f, after: true)
    }

    /// Rows a merge touches can't travel alone (the covered rows or the
    /// merge's lower half would be left behind), so their handles sit idle.
    func canMoveRow(_ row: Int) -> Bool {
        table.rows.indices.contains(row) && !table.rowspanCrosses(rows: row, row)
    }

    // Height and focus travel with the row; the drag-start snapshot is the
    // single undo step.
    func moveRow(from source: Int, to destination: Int, before: EditorSnapshot) {
        let count = table.rows.count
        let dest = min(max(destination, 0), count - 1)
        guard table.rows.indices.contains(source), dest != source,
              !table.rowspanCrosses(rows: source, source),
              !table.rowspanSplitsBand(min(source, dest), max(source, dest)) else { return }
        let toOffset = dest > source ? dest + 1 : dest
        table.rows.move(fromOffsets: IndexSet(integer: source), toOffset: toOffset)
        if rowHeights.indices.contains(source) {
            rowHeights.move(fromOffsets: IndexSet(integer: source), toOffset: toOffset)
        }
        if let f = focusedCell, f.row == source {
            focusedCell = GridCell(row: dest, column: f.column)
        }
        table.normalize()
        ensureSizing()
        flushToDocument()
        regenerateHTML()
        // Cells changed rows; text views must re-apply their content.
        contentRevision += 1
        registerResizeUndo(name: "Move Row", before: before)
    }

    // Grid column → array index; colspans shift the two apart.
    func cellIndex(containingColumn col: Int, in row: TableRow) -> Int? {
        var position = 0
        for (index, cell) in row.enumerated() {
            let span = min(max(cell.colspan, TableCell.minColspan), TableCell.maxColspan)
            if col >= position && col < position + span { return index }
            position += span
        }
        return nil
    }

    // A colspan cell wouldn't travel with the column, and a rowspan cell
    // spans several rows of alignment, so merge-touched columns stay
    // un-grabbable.
    func canMoveColumn(_ col: Int) -> Bool {
        !table.columnHasMerge(col)
    }

    // Width and focus travel with the column; cells are matched by grid
    // column, not array index, so colspan rows stay consistent.
    func moveColumn(from source: Int, to destination: Int, before: EditorSnapshot) {
        let count = table.columnCount
        let dest = min(max(destination, 0), count - 1)
        guard source >= 0, source < count, dest != source,
              !table.colspanSplitsBand(min(source, dest), max(source, dest)) else { return }
        let toOffset = dest > source ? dest + 1 : dest
        if columnWidths.indices.contains(source) {
            columnWidths.move(fromOffsets: IndexSet(integer: source), toOffset: toOffset)
        }
        for row in table.rows.indices {
            guard let srcIdx = cellIndex(containingColumn: source, in: table.rows[row]),
                  let anchor = cellIndex(containingColumn: dest, in: table.rows[row]) else { continue }
            // Moving right, the column lands after whatever owns the target
            // column; moving left, before it.
            var insertAt = dest > source ? anchor + 1 : anchor
            let cell = table.rows[row].remove(at: srcIdx)
            if srcIdx < insertAt { insertAt -= 1 }
            table.rows[row].insert(cell, at: min(insertAt, table.rows[row].count))
        }
        if let f = focusedCell {
            var col = f.column
            if col == source {
                col = dest
            } else if dest > source, col > source, col <= dest {
                col -= 1
            } else if dest < source, col >= dest, col < source {
                col += 1
            }
            if col != f.column { focusedCell = GridCell(row: f.row, column: col) }
        }
        table.normalize()
        ensureSizing()
        // Widths travel with columns; rewrap rows in case that changed fits.
        refreshRowHeights()
        flushToDocument()
        regenerateHTML()
        // Cells changed columns; text views must re-apply their content.
        contentRevision += 1
        registerResizeUndo(name: "Move Column", before: before)
    }

    func toggleHeader() {
        let targets = formattingCells()
        guard !targets.isEmpty else { return }
        let makeHeader = !targets.allSatisfy { cell(row: $0.row, col: $0.col)?.isHeader ?? false }
        let label = targets.count == 1
            ? (makeHeader ? "Make Header Cell" : "Make Body Cell")
            : (makeHeader ? "Make Header Cells" : "Make Body Cells")
        performUndoable(label) {
            for t in targets { self.table.rows[t.row][t.col].isHeader = makeHeader }
            // <thead> belongs to all-<th> rows: the last header cell leaving
            // drops the row to the body, the first one back wins it again.
            for row in Set(targets.map(\.row))
            where self.table.rows[row].allHeaders && self.table.rows[row].section == .body {
                self.table.rows[row].section = .head
            }
            self.demoteNonHeaderRows()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func setColspan(_ value: Int) {
        guard let f = focusedCell else { return }
        setColspan(value, for: f)
    }

    /// Cell-specific variant for the context menu, which acts on the
    /// right-clicked cell (like the row/column commands) rather than the focus.
    func setColspan(_ value: Int, for cell: GridCell) {
        guard let c = self.cell(row: cell.row, col: cell.column), c.colspan != value else { return }
        performUndoable("Set Column Span") {
            self.applyColspan(Table.clampedSpan(value), to: cell)
            // The wider cell may still overflow the current height.
            self.growRowIfNeeded(cell.row)
            // The span may have grown the table (new column widths) or padded
            // a header row with a plain cell (losing its <thead>).
            self.ensureSizing()
            self.demoteNonHeaderRows()
            // A context-menu span can swallow the focused cell.
            self.keepFocusValid()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    /// Extending a span destroys the cells it swallows, content and all;
    /// shrinking it — or extending past the table's edge — pads the row, and
    /// every other row when the table grows, with fresh empty cells so the
    /// grid stays rectangular.
    private func applyColspan(_ span: Int, to cell: GridCell) {
        guard let p = placement(of: cell) else { return }
        let end = p.startCol + span
        // Swallowed cells: this row's own cells, after the target, whose
        // visual start falls inside the new span. Placements run in array
        // order, so remove from the back to keep indices valid.
        let doomed = table.placements()[cell.row]
            .filter { $0.cellIndex > cell.column && $0.startCol < end }
            .map(\.cellIndex)
        for index in doomed.reversed() {
            table.rows[cell.row].remove(at: index)
        }
        table.rows[cell.row][cell.column].colspan = span
        // Pads the row (and, when the span widened the table, every row) back
        // to full width; also trims anything left overfull.
        table.normalize()
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        let targets = formattingCells()
        guard !targets.isEmpty else { return }
        // Nothing to do when every targeted cell already carries the value.
        guard targets.contains(where: { cell(row: $0.row, col: $0.col)?.alignment != alignment }) else { return }
        performUndoable("Set Alignment") {
            for t in targets {
                self.table.rows[t.row][t.col].alignment = alignment
            }
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    /// The alignment of the focused cell, or of every slot intersecting a
    /// multi-cell selection; a mixed selection reports the default so the
    /// toolbar button never lies.
    var alignment: NSTextAlignment {
        let targets = formattingCells()
        guard !targets.isEmpty else { return .left }
        let values = Set(targets.compactMap { cell(row: $0.row, col: $0.col)?.alignment })
        return values.count == 1 ? values.first ?? .left : .left
    }

    var colspanBinding: Binding<Int> {
        Binding(
            get: {
                guard let f = self.focusedCell, let c = self.cell(row: f.row, col: f.column) else { return 1 }
                return c.colspan
            },
            set: { self.setColspan($0) }
        )
    }

    // MARK: - Merging

    /// The selection rectangle, validated for merging: bigger than one cell,
    /// within the span limits, inside one row section, and no existing merge
    /// crosses its border (those would be cut in half).
    private var mergeRect: VisualCellRange? {
        guard let sel = cellSelection,
              table.rows.indices.contains(sel.rowStart),
              table.rows.indices.contains(sel.rowEnd),
              sel.colStart >= 0, sel.colEnd < table.columnCount,
              sel.rowEnd - sel.rowStart + 1 <= TableCell.maxRowspan,
              sel.colEnd - sel.colStart + 1 <= TableCell.maxColspan,
              Set(table.rows[sel.rowStart...sel.rowEnd].map(\.section)).count == 1
        else { return nil }
        for (row, slots) in table.placements().enumerated() {
            for p in slots where sel.intersects(row: row, rowSpan: p.rowSpan,
                                                startCol: p.startCol, span: p.colSpan) {
                let inside = row >= sel.rowStart && row + p.rowSpan - 1 <= sel.rowEnd
                    && p.startCol >= sel.colStart && p.startCol + p.colSpan - 1 <= sel.colEnd
                if !inside { return nil }
            }
        }
        return sel
    }

    var canMergeSelection: Bool { mergeRect != nil }

    /// Collapse the selection to its top-left cell, which keeps its content;
    /// every other cell inside the rectangle is removed.
    func mergeSelection() {
        guard let sel = mergeRect else { return }
        performUndoable("Merge Cells") {
            guard let top = self.table.cellCovering(row: sel.rowStart, col: sel.colStart) else { return }
            for row in sel.rowStart...sel.rowEnd {
                let doomed = self.table.placements()[row]
                    .filter { $0.startCol >= sel.colStart && $0.startCol + $0.colSpan - 1 <= sel.colEnd }
                    .map(\.cellIndex)
                    .filter { !(row == top.row && $0 == top.cell) }
                    .sorted(by: >)
                for index in doomed { self.table.rows[row].remove(at: index) }
            }
            var survivor = self.table.rows[top.row][top.cell]
            survivor.colspan = sel.colEnd - sel.colStart + 1
            survivor.rowspan = sel.rowEnd - sel.rowStart + 1
            // The merged interior is the model's own from here on.
            survivor.rawInnerHTML = nil
            survivor.selectionRange = NSRange(location: 0, length: survivor.content.length)
            self.table.rows[top.row][top.cell] = survivor
            self.table.normalize()
            // A merge can shorten a header row below full width; normalize's
            // padding cell costs the row its all-<th> status and its <thead>.
            self.demoteNonHeaderRows()
            self.ensureSizing()
            self.cellSelection = nil
            self.focusedCell = GridCell(row: top.row, column: top.cell)
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    var canSplitFocused: Bool {
        guard let f = focusedCell, let p = placement(of: f) else { return false }
        return p.colSpan > 1 || p.rowSpan > 1
    }

    /// Undo one merge: the cell goes back to 1×1 and empty cells take back
    /// the columns it freed, in its row and in every row it covered.
    func splitFocusedCell() {
        guard let f = focusedCell, let p = placement(of: f), p.colSpan > 1 || p.rowSpan > 1 else { return }
        performUndoable("Split Cells") {
            // Where each covered row reclaims the freed columns, as array
            // indices computed before anything moves.
            let slots = self.table.placements()
            var insertions: [(row: Int, at: Int)] = []
            for row in (f.row + 1)..<(f.row + p.rowSpan) where row < self.table.rows.count {
                let at = slots[row].first { $0.startCol >= p.startCol }?.cellIndex
                    ?? self.table.rows[row].count
                insertions.append((row, at))
            }
            var cell = self.table.rows[f.row][f.column]
            cell.colspan = 1
            cell.rowspan = 1
            cell.rawInnerHTML = nil
            self.table.rows[f.row][f.column] = cell
            // Freed cells inherit the row's header status, so splitting a
            // <th> yields <th>s and the row keeps its <thead>.
            for offset in 1..<p.colSpan {
                self.table.rows[f.row].insert(TableCell(isHeader: self.table.rows[f.row].allHeaders),
                                              at: f.column + offset)
            }
            for (row, at) in insertions {
                for offset in 0..<p.colSpan {
                    self.table.rows[row].insert(TableCell(isHeader: self.table.rows[row].allHeaders),
                                                at: at + offset)
                }
            }
            self.table.normalize()
            self.demoteNonHeaderRows()
            self.ensureSizing()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    // MARK: - Caption

    static let captionKey = GridCell(row: -2, column: -2)

    var hasCaption: Bool { table.caption != nil }

    var captionBinding: Binding<String> {
        Binding(
            get: { self.table.caption?.string ?? "" },
            set: { self.updateCaption($0) }
        )
    }

    func updateCaption(_ text: String) {
        guard let existing = table.caption else { return }
        let attributed = HTMLParser.plainAttributed(text)
        guard !existing.isEqual(to: attributed) else { return }
        let before = currentSnapshot()
        table.caption = attributed
        table.captionRaw = nil
        flushToDocument()
        regenerateHTML()
        // The HTML pane refreshes on revision ticks; without one the
        // caption typing would land in the model but not on screen.
        contentRevision += 1
        appendTypingChange(key: Self.captionKey, name: "Edit Caption", before: before)
    }

    func toggleCaption() {
        performUndoable(table.caption == nil ? "Show Caption" : "Hide Caption") {
            self.table.caption = self.table.caption == nil ? HTMLParser.plainAttributed("") : nil
            self.table.captionRaw = nil
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    // MARK: - Row sections

    var focusedRowSection: RowSection? {
        guard let f = focusedCell, table.rows.indices.contains(f.row) else { return nil }
        return table.rows[f.row].section
    }

    func setFocusedRowSection(_ section: RowSection) {
        guard let f = focusedCell, table.rows.indices.contains(f.row),
              table.rows[f.row].section != section else { return }
        performUndoable("Set Row Section") {
            self.table.rows[f.row].section = section
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    /// A row keeps <thead> only while it is nothing but header cells; a row
    /// that gains a plain cell drops to the body. toggleHeader adds it back.
    private func demoteNonHeaderRows() {
        for row in table.rows.indices
        where table.rows[row].section == .head && !table.rows[row].allHeaders {
            table.rows[row].section = .body
        }
    }

    // MARK: - Table attributes

    @Published var showTableAttributes = false
    @Published var attributesDraft: [HTMLAttribute] = []
    /// Accessibility emission toggles, mirrored from the table when the
    /// sheet opens and written back on commit (an undoable attribute edit).
    @Published var accessibilityScope: Bool = false
    @Published var accessibilitySRText: Bool = false

    func beginTableAttributes() {
        flushToDocument()
        // The title has its own dialog; the sheet owns everything else.
        attributesDraft = table.attributes
        accessibilityScope = table.accessibilityScope
        accessibilitySRText = table.accessibilitySRText
        showTableAttributes = true
    }

    func addAttributeRow() { attributesDraft.append(HTMLAttribute(name: "", value: "")) }

    func removeAttributeRow(at index: Int) {
        guard attributesDraft.indices.contains(index) else { return }
        attributesDraft.remove(at: index)
    }

    func cancelTableAttributes() { showTableAttributes = false }

    func commitTableAttributes() {
        showTableAttributes = false
        // Later duplicates edit the earlier one instead of doubling up.
        var cleaned: [HTMLAttribute] = []
        for attribute in attributesDraft {
            let name = attribute.name.trimmingCharacters(in: .whitespaces).lowercased()
            // Titles live in file names; a hand-typed legacy attribute is
            // dropped rather than re-emitted.
            guard !name.isEmpty, name != "data-table-name" else { continue }
            if let existing = cleaned.firstIndex(where: { $0.name == name }) {
                cleaned[existing].value = attribute.value
            } else {
                cleaned.append(HTMLAttribute(name: name, value: attribute.value))
            }
        }
        guard cleaned != table.attributes || accessibilityScope != table.accessibilityScope
            || accessibilitySRText != table.accessibilitySRText else { return }
        performUndoable("Edit Table Attributes") {
            self.table.attributes = cleaned
            self.table.accessibilityScope = self.accessibilityScope
            self.table.accessibilitySRText = self.accessibilitySRText
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func toggleBold() {
        applyTraitToggle(name: "Toggle Bold", trait: .boldFontMask) { font, manager, remove in
            manager.convert(font, toHaveTrait: remove ? .unboldFontMask : .boldFontMask)
        }
    }

    func toggleItalic() {
        applyTraitToggle(name: "Toggle Italic", trait: .italicFontMask) { font, manager, remove in
            manager.convert(font, toHaveTrait: remove ? .unitalicFontMask : .italicFontMask)
        }
    }

    /// The cells a formatting command applies to: every slot intersecting a
    /// multi-cell drag selection (whole cells — a merge cannot be half-styled),
    /// else the focused cell's text selection, whole cell if none.
    private func formattingCells() -> [(row: Int, col: Int, range: NSRange)] {
        if let sel = cellSelection {
            let cells = table.placements().enumerated().flatMap { row, slots in
                slots.filter { p in
                    sel.intersects(row: row, rowSpan: p.rowSpan, startCol: p.startCol, span: p.colSpan)
                }.map { p in (row: row, col: p.cellIndex, range: table.rows[row][p.cellIndex].fullRange) }
            }
            if cells.count > 1 { return cells }
        }
        guard let f = focusedCell, let c = cell(row: f.row, col: f.column) else { return [] }
        let range = c.selectionRange.length > 0 ? c.selectionRange : c.fullRange
        return [(row: f.row, col: f.column, range: range)]
    }

    // NSFont has no .weight/.symbolicTraits in this SDK and the trait-mask
    // types aren't nameable, so NSFontManager does the arithmetic.
    private func applyTraitToggle(name: String, trait: NSFontTraitMask,
                                  _ transform: (NSFont, NSFontManager, Bool) -> NSFont) {
        let targets = formattingCells()
        let multi = targets.count > 1
        // One decision for a whole multi-cell selection: strip the trait only
        // when every targeted character already has it; otherwise apply it.
        let remove = multi && targets.allSatisfy { target in
            guard let c = cell(row: target.row, col: target.col), target.range.length > 0 else { return true }
            var all = true
            c.content.enumerateAttribute(.font, in: target.range) { value, _, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                if !NSFontManager.shared.traits(of: font).contains(trait) { all = false }
            }
            return all
        }
        guard targets.contains(where: { $0.range.length > 0 }) else { return }
        performUndoable(name) {
            let manager = NSFontManager.shared
            var touchedRows = Set<Int>()
            for target in targets {
                guard let c = self.cell(row: target.row, col: target.col), target.range.length > 0 else { continue }
                let mutable = NSMutableAttributedString(attributedString: c.content)
                mutable.enumerateAttribute(.font, in: target.range) { value, subRange, _ in
                    let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    // A single cell toggles per run (each run's own state
                    // decides); a multi-cell selection applies one decision.
                    let flip = multi ? remove : manager.traits(of: font).contains(trait)
                    mutable.addAttribute(.font, value: transform(font, manager, flip), range: subRange)
                }
                self.table.rows[target.row][target.col].content = mutable
                self.table.rows[target.row][target.col].rawInnerHTML = nil
                touchedRows.insert(target.row)
            }
            // Bolder/wider glyphs can push wrapped text to extra lines.
            for row in touchedRows.sorted() { self.growRowIfNeeded(row) }
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    /// Delete/⌘⌫ across a cell block empties every cell it touches — the
    /// same whole-cell targets formatting uses — as one undoable step.
    /// Returns true when a block consumed the chord.
    @discardableResult
    func clearSelectedCells() -> Bool {
        let targets = formattingCells()
        guard targets.count > 1 else { return false }
        let nonEmpty = targets.filter { (cell(row: $0.row, col: $0.col)?.content.length ?? 0) > 0 }
        guard !nonEmpty.isEmpty else { return true }
        performUndoable("Delete Cells") {
            for t in nonEmpty {
                self.table.rows[t.row][t.col].content = NSAttributedString(string: "")
                self.table.rows[t.row][t.col].rawInnerHTML = nil
            }
            self.flushToDocument()
            self.regenerateHTML()
        }
        return true
    }

    var isHeaderActive: Bool {
        let targets = formattingCells()
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { self.cell(row: $0.row, col: $0.col)?.isHeader ?? false }
    }

    // Toolbar toggles read "on" only when every character of every targeted
    // cell already carries the trait.
    private func selectionHasTrait(_ trait: NSFontTraitMask) -> Bool {
        let targets = formattingCells().filter { $0.range.length > 0 }
        guard !targets.isEmpty else { return false }
        for target in targets {
            guard let c = cell(row: target.row, col: target.col) else { continue }
            var all = true
            c.content.enumerateAttribute(.font, in: target.range) { value, _, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                if !NSFontManager.shared.traits(of: font).contains(trait) { all = false }
            }
            if !all { return false }
        }
        return true
    }

    var isBoldActive: Bool { selectionHasTrait(.boldFontMask) }
    var isItalicActive: Bool { selectionHasTrait(.italicFontMask) }

    var headerBinding: Binding<Bool> {
        Binding(
            get: { self.isHeaderActive },
            set: { _ in self.toggleHeader() }
        )
    }

    var boldBinding: Binding<Bool> {
        Binding(
            get: { self.isBoldActive },
            set: { wanted in if wanted != self.isBoldActive { self.toggleBold() } }
        )
    }

    var italicBinding: Binding<Bool> {
        Binding(
            get: { self.isItalicActive },
            set: { wanted in if wanted != self.isItalicActive { self.toggleItalic() } }
        )
    }

    func beginLinkEntry() {
        guard focusedCell != nil else { return }
        closeTypingGroup()
        linkURLText = ""
        showLinkPrompt = true
    }

    func applyLink() {
        defer { showLinkPrompt = false }
        let trimmed = linkURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let f = focusedCell,
              let c = cell(row: f.row, col: f.column) else { return }
        let urlString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: urlString) else { return }
        let range = c.selectionRange.length > 0 ? c.selectionRange : c.fullRange
        guard range.length > 0 else { return }
        performUndoable("Insert Link") {
            let mutable = NSMutableAttributedString(attributedString: c.content)
            mutable.addAttribute(.link, value: url, range: range)
            self.table.rows[f.row][f.column].content = mutable
            self.table.rows[f.row][f.column].rawInnerHTML = nil
            self.linkURLText = ""
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func newTable() {
        flushToDocument()
        let doc = TableDocument.new(name: "Table \(documents.count + 1)")
        documents.append(doc)
        loadDocument(doc)
        sidebarSelection = [doc.id]
    }

    func selectDocument(_ id: UUID) {
        guard id != selectedDocumentID, let doc = document(id: id) else { return }
        flushToDocument()
        loadDocument(doc)
    }

    /// The tables the sidebar commands act on: the whole ⌘-selection,
    /// falling back to the open table.
    var selectedDocumentIDs: Set<UUID> {
        sidebarSelection.isEmpty ? Set(selectedDocumentID.map { [$0] } ?? []) : sidebarSelection
    }

    /// The sidebar list's selection: plain click replaces, ⌘-click toggles.
    /// The editor follows the last-clicked table; clearing keeps the open one.
    func applySidebarSelection(_ new: Set<UUID>) {
        let old = sidebarSelection
        guard new != old else { return }
        sidebarSelection = new
        let added = new.subtracting(old)
        let primary: UUID?
        if let a = added.first {
            primary = a
        } else if let cur = selectedDocumentID, new.contains(cur) {
            primary = cur
        } else {
            primary = new.isEmpty ? nil : documents.first { new.contains($0.id) }?.id
        }
        if let primary, primary != selectedDocumentID { selectDocument(primary) }
    }

    /// Inline sidebar rename: keystrokes update the in-memory name only; the
    /// file follows when editing commits (commitInlineRename).
    func renameDocument(_ id: UUID, to newName: String) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        documents[idx].name = trimmed.isEmpty ? "Untitled Table" : trimmed
        if id == selectedDocumentID {
            table.name = documents[idx].name
        }
    }

    /// Commits an inline sidebar rename: the file is moved to the new name.
    func commitInlineRename(_ id: UUID) {
        renameFileToMatchName(id)
    }

    /// Moves the document's file so its stem is the sanitized name. No-op when
    /// unsaved (the first save derives the name) or when it already matches.
    private func renameFileToMatchName(_ id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }),
              let oldURL = documents[idx].fileURL else { return }
        let newStem = Self.sanitizedFileName(documents[idx].name)
        guard newStem != oldURL.deletingPathExtension().lastPathComponent else { return }
        // Uniquify against other tables' files and orphans on disk (which
        // would be clobbered by the move), but not the table's own file.
        var taken = Set(documents.compactMap { $0.id == id ? nil : $0.fileURL?.path })
        taken.formUnion((try? FileManager.default.contentsOfDirectory(
            at: Self.saveDirectory, includingPropertiesForKeys: nil))?.map(\.path) ?? [])
        taken.remove(oldURL.path)
        let newURL = Self.uniqueFileURL(for: newStem, taken: &taken)
        guard newURL != oldURL,
              (try? FileManager.default.moveItem(at: oldURL, to: newURL)) != nil else { return }
        documents[idx].fileURL = newURL
        // Persist now: a rename with no further edits must not wait for the
        // next autosave.
        saveAllDocuments()
    }

    /// Opens the rename sheet pre-filled with the title; the filename is shown
    /// (derived from the title) but not editable. Nil means the selection.
    func beginRename(_ id: UUID? = nil) {
        guard let id = id ?? selectedDocumentID, let doc = document(id: id) else { return }
        renamingID = id
        renameTitleText = doc.name
        showRenamePrompt = true
    }

    func cancelRename() { showRenamePrompt = false }

    func commitRename() {
        showRenamePrompt = false
        guard let id = renamingID else { return }
        let title = renameTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        applyRename(id: id, title: title)
    }

    /// Sets the title and moves the file to the sanitized name, undoable as
    /// one step. The filename is always derived from the title.
    private func applyRename(id: UUID, title: String) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        closeTypingGroup()
        flushToDocument()

        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID
        let oldTitle = documents[idx].name
        let oldURL = documents[idx].fileURL

        documents[idx].name = title
        if id == selectedDocumentID {
            table.name = title
        }
        renameFileToMatchName(id)

        let afterDocuments = deepCopied(documents)
        let afterSelection = selectedDocumentID
        registerFileRenameUndo(undoFile: oldURL, redoFile: documents[idx].fileURL, name: "Rename \(oldTitle)",
                               undoDocs: beforeDocuments, undoSelection: beforeSelection,
                               redoDocs: afterDocuments, redoSelection: afterSelection)
    }

    /// Like registerDocumentUndo, plus the file itself travels with the
    /// document snapshot in both directions.
    private func registerFileRenameUndo(undoFile: URL?, redoFile: URL?, name: String,
                                        undoDocs: [TableDocument], undoSelection: UUID?,
                                        redoDocs: [TableDocument], redoSelection: UUID?) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.moveFile(from: redoFile, to: undoFile)
            target.registerFileRenameUndo(undoFile: redoFile, redoFile: undoFile, name: name,
                                          undoDocs: redoDocs, undoSelection: redoSelection,
                                          redoDocs: undoDocs, redoSelection: undoSelection)
            target.restoreDocuments(undoDocs, selection: undoSelection)
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    private func moveFile(from: URL?, to: URL?) {
        guard let from, let to, FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.moveItem(at: from, to: to)
    }

    func duplicateDocument(_ id: UUID) {
        duplicateDocuments([id])
    }

    /// Each copy lands directly below its source; the batch is one undo step
    /// (per-ID loads would clear the stack and orphan earlier steps) and the
    /// copies become the selection.
    func duplicateDocuments(_ ids: Set<UUID>) {
        let ordered = documents.filter { ids.contains($0.id) }
        guard !ordered.isEmpty else { return }
        closeTypingGroup()
        flushToDocument()
        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID

        var copyIDs: [UUID] = []
        for source in ordered {
            // Fresh cells and a fresh id: editing the copy must not touch the source.
            var copyTable = source.table.deepCopied(id: UUID())
            copyTable.name = uniqueTableName(source.name)
            let copy = TableDocument(table: copyTable, fileURL: nil)
            guard let idx = documents.firstIndex(where: { $0.id == source.id }) else { continue }
            documents.insert(copy, at: idx + 1)
            copyIDs.append(copy.id)
        }
        guard let lastID = copyIDs.last, let lastDoc = document(id: lastID) else { return }
        loadDocument(lastDoc)
        sidebarSelection = Set(copyIDs)

        let afterDocuments = deepCopied(documents)
        let afterSelection = selectedDocumentID
        // loadDocument clears the undo stack, so the pair registers after it.
        let name = ordered.count == 1 ? "Duplicate \(ordered[0].name)" : "Duplicate \(ordered.count) Tables"
        registerDocumentUndo(name: name,
                             undoTo: beforeDocuments, undoSelection: beforeSelection,
                             redoTo: afterDocuments, redoSelection: afterSelection)
    }

    // Finder-style naming: "X copy", then "X copy 2", skipping taken names.
    private func uniqueTableName(_ base: String) -> String {
        let taken = Set(documents.map(\.name))
        var candidate = "\(base) copy"
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base) copy \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Deleting a table is undoable: the whole document list plus the
    /// selection are snapshotted and restored as one step. Batches pass
    /// registerUndo: false and register a single combined step themselves —
    /// the editor fallback's loadDocument clears the stack mid-batch, which
    /// would orphan the earlier steps.
    func deleteDocument(_ id: UUID, registerUndo: Bool = true) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        closeTypingGroup()
        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID
        let removedName = documents[idx].name
        let removedFileURL = documents[idx].fileURL

        documents.remove(at: idx)
        savedHTML.removeValue(forKey: id)
        sidebarSelection.remove(id)
        // The file goes with it; an undo restores the table and the next
        // autosave pass writes the file back.
        if let removedFileURL {
            try? FileManager.default.removeItem(at: removedFileURL)
        }
        if id == selectedDocumentID {
            // Zero tables is a valid state: the content pane shows an
            // empty state instead of auto-recreating a document.
            selectedDocumentID = nil
            focusedCell = nil
            // The editor falls to the next ⌘-selected table, not just the
            // first document.
            let next = documents.first { sidebarSelection.contains($0.id) } ?? documents.first
            if let next {
                loadDocument(next)
                sidebarSelection = [next.id]
            } else {
                sidebarSelection = []
            }
        }

        guard registerUndo else { return }
        let afterDocuments = deepCopied(documents)
        let afterSelection = selectedDocumentID
        // registerDocumentUndo registers the entry AND restores inside its
        // handler on undo, so no extra wrapper here.
        registerDocumentUndo(name: "Delete \(removedName)",
                             undoTo: beforeDocuments, undoSelection: beforeSelection,
                             redoTo: afterDocuments, redoSelection: afterSelection)
    }

    private func registerDocumentUndo(name: String,
                                      undoTo: [TableDocument], undoSelection: UUID?,
                                      redoTo: [TableDocument], redoSelection: UUID?) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.registerDocumentUndo(name: name,
                                        undoTo: redoTo, undoSelection: redoSelection,
                                        redoTo: undoTo, redoSelection: undoSelection)
            target.restoreDocuments(undoTo, selection: undoSelection)
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    private func restoreDocuments(_ docs: [TableDocument], selection: UUID?) {
        documents = deepCopied(docs)
        if let sel = selection, let doc = documents.first(where: { $0.id == sel }) {
            loadDocument(doc)
            sidebarSelection = [sel]
        } else if let first = documents.first {
            loadDocument(first)
            sidebarSelection = [first.id]
        } else {
            // Undo restored the zero-tables state.
            selectedDocumentID = nil
            focusedCell = nil
            sidebarSelection = []
        }
    }

    func duplicateSelectedDocument() {
        duplicateDocuments(selectedDocumentIDs)
    }

    func deleteSelectedDocument() {
        deleteDocuments(selectedDocumentIDs)
    }

    /// One undo step for the whole batch; the captured IDs stay valid as the
    /// list shrinks, and the combined registration lands after the editor
    /// fallback's loadDocument has cleared the stack.
    func deleteDocuments(_ ids: Set<UUID>) {
        let ordered = documents.filter { ids.contains($0.id) }
        guard !ordered.isEmpty else { return }
        closeTypingGroup()
        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID
        for doc in ordered { deleteDocument(doc.id, registerUndo: false) }
        let afterDocuments = deepCopied(documents)
        let afterSelection = selectedDocumentID
        let name = ordered.count == 1
            ? "Delete \(ordered[0].name)"
            : "Delete \(ordered.count) Tables"
        registerDocumentUndo(name: name,
                             undoTo: beforeDocuments, undoSelection: beforeSelection,
                             redoTo: afterDocuments, redoSelection: afterSelection)
    }

    func deleteDocument(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { idx in idx < documents.count ? documents[idx].id : nil })
        deleteDocuments(ids)
    }

    // MARK: - Templates

    /// Menu and manager order: alphabetical, like the files they are stored as.
    var sortedTemplates: [TableDocument] {
        templates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Save as Template…". A context-menu row need not be the selected table,
    /// so its own rows are the snapshot; the live table needs a flush first.
    func beginTemplateSave(from id: UUID? = nil) {
        flushToDocument()
        let source = id.flatMap { document(id: $0) }?.table ?? table
        // Fresh id: a template must never share identity with its source.
        templateDraftTable = source.deepCopied(id: UUID())
        templateNameText = source.name
        showTemplatePrompt = true
    }

    func saveAsTemplate() {
        defer { showTemplatePrompt = false }
        let typed = templateNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        // Fresh id per save: the same draft may be saved several times.
        var table = (templateDraftTable ?? Table.new()).deepCopied(id: UUID())
        table.name = uniqueName(typed, avoiding: Set(templates.map(\.name)))
        table.normalize()
        var template = TableDocument(table: table, fileURL: nil)
        guard let url = Self.writeTemplate(template) else { return }
        template.fileURL = url
        templates.append(template)
        templateNameText = ""
    }

    /// A fresh document carrying the template's markup, named after the
    /// template and numbered if a table already owns that name.
    func newTable(fromTemplate template: TableDocument) {
        flushToDocument()
        // Fresh id: the new table is its own document, not the template.
        var table = template.table.deepCopied(id: UUID())
        table.name = uniqueName(template.name, avoiding: Set(documents.map(\.name)))
        table.normalize()
        let doc = TableDocument(table: table, fileURL: nil)
        documents.append(doc)
        loadDocument(doc)
        sidebarSelection = [doc.id]
    }

    /// Renaming moves the file. The old one goes only after the new write
    /// succeeds, so a failed write cannot destroy the template.
    func renameTemplate(_ id: UUID, to newName: String) {
        guard let idx = templates.firstIndex(where: { $0.id == id }) else { return }
        let typed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = templates[idx].name
        guard !typed.isEmpty, typed != previous else { return }
        var others = Set(templates.map(\.name))
        others.remove(previous)
        templates[idx].name = uniqueName(typed, avoiding: others)
        guard let url = Self.writeTemplate(templates[idx]) else {
            templates[idx].name = previous
            return
        }
        if let old = templates[idx].fileURL, old != url { try? FileManager.default.removeItem(at: old) }
        templates[idx].fileURL = url
    }

    func deleteTemplate(_ id: UUID) {
        guard let idx = templates.firstIndex(where: { $0.id == id }) else { return }
        if let url = templates[idx].fileURL { try? FileManager.default.removeItem(at: url) }
        templates.remove(at: idx)
    }

    /// "Base", then "Base 2", "Base 3"… until the name is free.
    private func uniqueName(_ base: String, avoiding taken: Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func loadDocument(_ document: TableDocument) {
        closeTypingGroup()
        selectedDocumentID = document.id
        table = document.table
        columnWidths = document.columnWidths
        rowHeights = document.rowHeights
        focusedCell = GridCell(row: 0, column: 0)
        cellSelection = nil
        ensureSizing()
        // Fresh tables start at the default height; grow to fit their text.
        // Revisits carry exact heights (grown once, plus manual resizes).
        // (restore() deliberately does NOT do this: snapshot heights are exact.)
        if document.rowHeights.isEmpty { refreshRowHeights() }
        regenerateHTML()
        // A file that loaded with markup complaints keeps showing them until
        // an edit normalizes it; regenerateHTML just cleared the live copy.
        markupDiagnostics = document.table.diagnostics
        contentRevision += 1
        // Undo history is per table; the old stack would restore stale rows.
        // During an undo/redo of a delete, keep the stack intact.
        if !undoManager.isUndoing && !undoManager.isRedoing {
            undoManager.removeAllActions()
        }
    }

    func ensureSizing() {
        let cols = table.columnCount
        while columnWidths.count < cols { columnWidths.append(Self.defaultColumnWidth) }
        if columnWidths.count > cols { columnWidths.removeLast(columnWidths.count - cols) }
        let rows = table.rows.count
        while rowHeights.count < rows { rowHeights.append(Self.defaultRowHeight) }
        if rowHeights.count > rows { rowHeights.removeLast(rowHeights.count - rows) }
    }

    func setColumnWidth(_ column: Int, to width: CGFloat) {
        guard column >= 0, column < columnWidths.count else { return }
        columnWidths[column] = max(Self.minColumnWidth, width)
        // Narrower columns rewrap their text; rows grow so it stays visible.
        refreshRowHeights()
    }

    func setRowHeight(_ row: Int, to height: CGFloat) {
        guard row >= 0, row < rowHeights.count else { return }
        rowHeights[row] = max(Self.minRowHeight, height)
    }

    private static let cellTextInset: CGFloat = 3

    // Grow-only: a manually shrunk row stays shrunk, so auto-sizing never
    // fights the resize handles.
    func growRowIfNeeded(_ row: Int) {
        guard row >= 0, row < rowHeights.count, row < table.rows.count else { return }
        var needed = TableViewModel.defaultRowHeight
        for p in table.placements()[row] {
            let width = cellWidth(startingAtCol: p.startCol, span: p.colSpan)
            let height = Self.requiredHeight(for: table.rows[row][p.cellIndex].content, width: width)
            if p.rowSpan == 1 {
                needed = max(needed, height)
            } else {
                // A tall cell gets every row it spans; a shortfall grows the
                // origin row rather than clipping the text.
                var available = CGFloat(p.rowSpan - 1) * WYSIWYGView.divider
                for spanned in row..<min(row + p.rowSpan, rowHeights.count) {
                    available += rowHeights[spanned]
                }
                if height > available { rowHeights[row] += height - available }
            }
        }
        let target = max(rowHeights[row], needed)
        if target != rowHeights[row] { rowHeights[row] = target }
    }

    private func refreshRowHeights() {
        for row in table.rows.indices { growRowIfNeeded(row) }
    }

    // Mirrors the cell text views' metrics (3pt insets, 5pt line-fragment
    // padding) so the layout engine measures the same box the text lays out in.
    private static func requiredHeight(for content: NSAttributedString, width: CGFloat) -> CGFloat {
        guard content.length > 0 else { return defaultRowHeight }
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: max(width - 2 * cellTextInset, 1),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height) + 2 * cellTextInset
    }

    func cellWidth(startingAtCol col: Int, span: Int) -> CGFloat {
        let end = min(col + span, columnWidths.count)
        guard col < end else { return Self.defaultColumnWidth }
        // A spanning cell also covers the dividers between its columns.
        return columnWidths[col..<end].reduce(0, +) + CGFloat(end - col - 1) * WYSIWYGView.divider
    }

    // Resize handles only sit where no row spans the boundary.
    func canResizeBoundary(afterCol col: Int) -> Bool {
        for row in table.rows {
            var position = 0
            for c in row {
                let span = min(max(c.colspan, TableCell.minColspan), TableCell.maxColspan)
                if position <= col && col < position + span - 1 { return false }
                position += span
            }
        }
        return true
    }

    // Typing coalesces into one write per pause.
    private static let autosaveDelay: TimeInterval = 0.8
    private var autosaveTimer: Timer?
    private var autosaveObserver: AnyCancellable?
    // Unchanged HTML is never rewritten, so the debounce pass costs no disk churn.
    private var savedHTML: [UUID: String] = [:]

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveDelay, repeats: false) { _ in
            Task { @MainActor in self.saveAllDocuments() }
        }
    }

    private func flushAndSaveAll() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        closeTypingGroup()
        saveAllDocuments()
    }

    // The filename always mirrors the name: the first save derives it, and a
    // rename (inline or dialog) has already moved the file to the new stem.
    func saveAllDocuments() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.saveDirectory, withIntermediateDirectories: true)
        var taken = Set<String>()
        for idx in documents.indices {
            let url = documents[idx].fileURL
                ?? Self.uniqueFileURL(for: documents[idx].name, taken: &taken)
            taken.insert(url.path)
            let html = HTMLGenerator.html(for: documents[idx].table)
            if documents[idx].fileURL == url, savedHTML[documents[idx].id] == html { continue }
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Failed to save table: \(error)")
                continue
            }
            savedHTML[documents[idx].id] = html
            documents[idx].fileURL = url
        }
    }

    private static func uniqueFileURL(for name: String, taken: inout Set<String>) -> URL {
        let base = sanitizedFileName(name)
        var candidate = saveDirectory.appendingPathComponent("\(base).html")
        var suffix = 2
        while taken.contains(candidate.path) {
            candidate = saveDirectory.appendingPathComponent("\(base) \(suffix).html")
            suffix += 1
        }
        taken.insert(candidate.path)
        return candidate
    }

    // Letters, digits, spaces and " -_.()" survive; the rest become '-' and
    // runs collapse.
    static func sanitizedFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.()"))
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? $0 : UnicodeScalar("-") }
        let cleaned = String(String.UnicodeScalarView(mapped))
            .split(separator: "-")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? "Untitled Table" : cleaned
    }

    // MARK: - Title store migration

    /// The old app kept display titles in a UserDefaults store keyed by file
    /// path, which a cold launch could wipe before the library grant resolved.
    /// The name is now the source of truth and the filename always mirrors it,
    /// so this one-time pass folds every stored title into its filename and
    /// drops the store.
    private static let titlesByPathKey = "TableTitlesByPath"
    // Keyed by the library path so a headless probe (its own directory) can't
    // mark the user's real library as migrated.
    private static var titlesMigratedKey: String {
        "TitlesMigratedToFileName-" + canonicalPath(saveDirectory)
    }

    // contentsOfDirectory reports symlinked paths resolved (/tmp → /private/tmp),
    // so both sides of the store must key on the canonical path or lookups miss.
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Rewrite store keys when the library root moves so titles survive the
    /// move (only meaningful before the migration has consumed the store).
    static func rekeyTitles(from oldRoot: URL, to newRoot: URL) {
        let o = canonicalPath(oldRoot), n = canonicalPath(newRoot)
        guard o != n,
              let map = UserDefaults.standard.dictionary(forKey: titlesByPathKey) as? [String: String] else { return }
        var rebuilt: [String: String] = [:]
        for (key, value) in map {
            if key == o || key.hasPrefix(o + "/") { rebuilt[n + key.dropFirst(o.count)] = value }
            else { rebuilt[key] = value }
        }
        UserDefaults.standard.set(rebuilt, forKey: titlesByPathKey)
    }

    /// Run once: rename each table file so its stem is the display name (from
    /// the old store, then a legacy in-file name, then the stem), then drop the
    /// store. Skips if the library can't be listed, so the store is never
    /// destroyed without being consumed.
    private static func migrateTitleStoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: titlesMigratedKey) else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: saveDirectory, includingPropertiesForKeys: nil) else { return }
        let files = contents
            .filter { $0.pathExtension.lowercased() == "html" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let store = (defaults.dictionary(forKey: titlesByPathKey) as? [String: String]) ?? [:]
        var taken = Set(files.map(\.path))
        for url in files {
            let stem = url.deletingPathExtension().lastPathComponent
            let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let legacy = HTMLParser.parseTable(html).legacyName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = store[canonicalPath(url)] ?? (legacy?.isEmpty == false ? legacy! : stem)
            let newStem = sanitizedFileName(name)
            guard newStem != stem else { continue }
            var candidate = saveDirectory.appendingPathComponent("\(newStem).html")
            var suffix = 2
            while taken.contains(candidate.path) {
                candidate = saveDirectory.appendingPathComponent("\(newStem) \(suffix).html")
                suffix += 1
            }
            guard (try? FileManager.default.moveItem(at: url, to: candidate)) != nil else { continue }
            taken.remove(url.path)
            taken.insert(candidate.path)
        }
        defaults.removeObject(forKey: titlesByPathKey)
        defaults.set(true, forKey: titlesMigratedKey)
    }

    private static func loadStoredDocuments() -> [TableDocument] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: saveDirectory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        let docs: [TableDocument] = urls
            .filter { $0.pathExtension.lowercased() == "html" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let html = try? String(contentsOf: url, encoding: .utf8) else {
                    NSLog("Skipping unreadable table file: \(url.path)")
                    return nil
                }
                let rawName = url.deletingPathExtension().lastPathComponent
                // Legacy saves named "----.html" surface as "Untitled Table".
                let stemName = Self.sanitizedFileName(rawName) == "Untitled Table" ? "Untitled Table" : rawName
                let parsed = HTMLParser.parseTable(html)
                return TableDocument(table: Table.loaded(from: parsed, name: stemName), fileURL: url)
            }
        return docs
    }

    func copyHTMLToClipboard() {
        closeTypingGroup()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(htmlText, forType: .string)
    }

    // MARK: - Cell copy / paste

    /// The selected rectangle as its own Table: slot spans clipped to the
    /// selection window, rows padded rectangular.
    private func subtable(of sel: VisualCellRange) -> Table {
        var rows: [[TableCell]] = []
        let placements = table.placements()
        for row in sel.rowStart...sel.rowEnd where table.rows.indices.contains(row) {
            var out: [TableCell] = []
            for p in placements[row]
            where sel.intersects(row: row, rowSpan: p.rowSpan, startCol: p.startCol, span: p.colSpan) {
                let lo = max(p.startCol, sel.colStart)
                let hi = min(p.startCol + p.colSpan - 1, sel.colEnd)
                guard lo <= hi else { continue }
                var cell = table.rows[row][p.cellIndex]
                cell.colspan = hi - lo + 1
                cell.rowspan = min(p.rowSpan, sel.rowEnd - row + 1)
                out.append(cell)
            }
            if !out.isEmpty { rows.append(out) }
        }
        var sub = Table(rows: rows, name: "Pasted Table")
        sub.normalize()
        return sub
    }

    /// ⌘C with a cell range selected copies the cells as a standalone HTML
    /// table (plus TSV) instead of the focused cell's text. True = handled.
    func copySelectedCells() -> Bool {
        guard let sel = cellSelection else { return false }
        let sub = subtable(of: sel)
        guard !sub.rows.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(HTMLGenerator.html(for: sub), forType: .html)
        pasteboard.setString(sub.rows.map { row in row.map(\.plainString).joined(separator: "\t") }
                                 .joined(separator: "\n"), forType: .string)
        return true
    }

    /// ⌘V inside a cell: when the clipboard holds a real HTML table (what
    /// copySelectedCells writes), promote it to its own document instead of
    /// dumping every cell's text into the focused cell. Plain text and links
    /// still paste into the cell. True = handled.
    func pasteTableFromPasteboardIfTable() -> Bool {
        guard let html = NSPasteboard.general.string(forType: .html),
              html.range(of: "<table", options: .caseInsensitive) != nil else { return false }
        pasteAsNewTable()
        return true
    }

    /// Creates a new table from the pasteboard — HTML table or tab/newline
    /// text — as one undoable step, the way Duplicate Table works.
    func pasteAsNewTable() {
        let pasteboard = NSPasteboard.general
        guard let source = pasteboard.string(forType: .html) ?? pasteboard.string(forType: .string),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let parsed = HTMLParser.parseTable(source)
        guard !parsed.rows.isEmpty else { return }
        closeTypingGroup()
        flushToDocument()
        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID

        let table = Table.loaded(from: parsed, name: uniquePastedName())
        let doc = TableDocument(table: table, fileURL: nil)
        documents.append(doc)
        loadDocument(doc)
        sidebarSelection = [doc.id]

        registerDocumentUndo(name: "Paste as New Table",
                             undoTo: beforeDocuments, undoSelection: beforeSelection,
                             redoTo: deepCopied(documents), redoSelection: selectedDocumentID)
    }

    private func uniquePastedName() -> String {
        let taken = Set(documents.map(\.name))
        var candidate = "Pasted Table"
        var suffix = 2
        while taken.contains(candidate) { candidate = "Pasted Table \(suffix)"; suffix += 1 }
        return candidate
    }

    /// True when a text view owns the caret. Field editors are NSTextViews, so
    /// cells, the source pane, renames and the link sheet are one check.
    static func caretInTextView(_ window: NSWindow?) -> Bool {
        window?.firstResponder is NSTextView
    }

    /// ⌘⌫ context: a cell block clears its cells; with no caret it deletes
    /// the table; otherwise the chord goes back to the text as the paragraph
    /// delete it names (a disabled menu item still swallows it).
    func deleteTableChordPressed() {
        if clearSelectedCells() { return }
        if Self.caretInTextView(NSApp.keyWindow) {
            NSApp.sendAction(#selector(NSText.deleteToBeginningOfParagraph(_:)), to: nil, from: nil)
        } else {
            deleteSelectedDocument()
        }
    }

    // Templates sit in a subfolder: contentsOfDirectory is not recursive, so
    // loadStoredDocuments can never list one as a table.
    static var templateDirectory: URL {
        saveDirectory.appendingPathComponent("Templates", isDirectory: true)
    }

    /// Writes one template and returns where it landed, or nil on failure.
    private static func writeTemplate(_ template: TableDocument) -> URL? {
        try? FileManager.default.createDirectory(at: templateDirectory, withIntermediateDirectories: true)
        let url = templateURL(for: template.name, excluding: template.fileURL)
        do {
            try HTMLGenerator.html(for: template.table).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Failed to save template: \(error)")
            return nil
        }
        return url
    }

    // Different names can sanitize to one file ("A/B" and "A-B"), so the
    // filesystem gets the suffix vote; a template's own file is never taken.
    private static func templateURL(for name: String, excluding own: URL?) -> URL {
        let base = sanitizedFileName(name)
        var candidate = templateDirectory.appendingPathComponent("\(base).html")
        var suffix = 2
        while candidate != own, FileManager.default.fileExists(atPath: candidate.path) {
            candidate = templateDirectory.appendingPathComponent("\(base) \(suffix).html")
            suffix += 1
        }
        return candidate
    }

    private static func loadStoredTemplates() -> [TableDocument] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: templateDirectory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "html" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let html = try? String(contentsOf: url, encoding: .utf8) else {
                    NSLog("Skipping unreadable template file: \(url.path)")
                    return nil
                }
                let table = Table.loaded(from: HTMLParser.parseTable(html),
                                         name: url.deletingPathExtension().lastPathComponent)
                return TableDocument(table: table, fileURL: url)
            }
    }

    // Headless harnesses set this: NSHomeDirectory() ignores $HOME for a bare
    // executable, so an env redirect cannot sandbox the library.
    static var saveDirectoryOverride: URL?

    static var saveDirectory: URL {
        if let override = saveDirectoryOverride { return override }
        return LibraryLocation.directory
    }
}
