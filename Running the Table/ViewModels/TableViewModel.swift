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

    /// True when a slot, which may span several columns, intersects the range.
    func intersects(row: Int, startCol: Int, span: Int) -> Bool {
        row >= rowStart && row <= rowEnd && startCol <= colEnd && startCol + span - 1 >= colStart
    }
}

/// Full editor state captured to revert one undo step.
struct EditorSnapshot {
    let documentID: UUID?
    let rows: [[TableCell]]
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
    let focusedCell: GridCell?
}

// Deliberately flat: nested ObservableObjects crash observation tracking.
@MainActor
final class TableViewModel: ObservableObject {
    @Published var documents: [TableDocument]
    @Published var selectedDocumentID: UUID?
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
    @Published var selectionRange = NSRange(location: 0, length: 0)
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
    private var templateDraftRows: [[TableCell]] = []

    // Prevents recursive WYSIWYG/HTML pane updates during sync.
    var isUpdating = false

    static let defaultColumnWidth: CGFloat = 140
    static let defaultRowHeight: CGFloat = 32
    static let minColumnWidth: CGFloat = 40
    static let minRowHeight: CGFloat = 24

    init() {
        // All previously saved tables return at launch; none means empty state.
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
        // Cache hits skip every write, so this only renames legacy files.
        saveAllDocuments()
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
                       rows: deepCopied(table.rows),
                       columnWidths: columnWidths,
                       rowHeights: rowHeights,
                       focusedCell: focusedCell)
    }

    private func restore(_ snapshot: EditorSnapshot) {
        // The snapshot may belong to another still-open table.
        if let docID = snapshot.documentID, docID != selectedDocumentID {
            guard let doc = documents.first(where: { $0.id == docID }) else { return }
            selectedDocumentID = docID
            table = doc.table
        }
        table.rows = deepCopied(snapshot.rows)
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
    private func deepCopied(_ rows: [[TableCell]]) -> [[TableCell]] {
        rows.map { row in
            row.map { cell in
                var copy = cell
                copy.content = NSAttributedString(attributedString: cell.content)
                return copy
            }
        }
    }

    private func deepCopied(_ documents: [TableDocument]) -> [TableDocument] {
        documents.map { doc in
            var copy = doc
            copy.table.rows = deepCopied(doc.table.rows)
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
        htmlText = HTMLGenerator.html(for: table)
        isUpdating = false
    }

    // Keystrokes coalesce into one undo run, like typing in a cell.
    func importFromHTML(_ html: String) {
        guard !isUpdating, html != htmlText else { return }
        let before = currentSnapshot()
        isUpdating = true
        htmlText = html
        table.rows = HTMLParser.parse(html)
        table.normalize()
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
            self.table.rows.insert(Array(repeating: TableCell(), count: cols), at: index)
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
        guard cell.row < table.rows.count, cell.column < table.rows[cell.row].count else { return }
        performUndoable(after ? "Add Column" : "Add Column Left") {
            for row in self.table.rows.indices {
                let insertAt = min(cell.column + (after ? 1 : 0), self.table.rows[row].count)
                self.table.rows[row].insert(TableCell(), at: insertAt)
            }
            self.table.normalize()
            self.ensureSizing()
            self.focusedCell = GridCell(row: cell.row, column: cell.column + (after ? 1 : 0))
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func removeRow() {
        guard let f = focusedCell, table.rows.count > 1, f.row < table.rows.count else { return }
        performUndoable("Remove Row") {
            self.table.rows.remove(at: f.row)
            self.table.normalize()
            self.ensureSizing()
            self.keepFocusValid()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func removeColumn() {
        guard let f = focusedCell, table.columnCount > 1,
              f.row < table.rows.count, f.column < table.rows[f.row].count else { return }
        performUndoable("Remove Column") {
            for row in self.table.rows.indices where f.column < self.table.rows[row].count {
                self.table.rows[row].remove(at: f.column)
            }
            self.table.normalize()
            self.ensureSizing()
            self.keepFocusValid()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    // Height and focus travel with the row; the drag-start snapshot is the
    // single undo step.
    func moveRow(from source: Int, to destination: Int, before: EditorSnapshot) {
        let count = table.rows.count
        let dest = min(max(destination, 0), count - 1)
        guard table.rows.indices.contains(source), dest != source else { return }
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
    func cellIndex(containingColumn col: Int, in row: [TableCell]) -> Int? {
        var position = 0
        for (index, cell) in row.enumerated() {
            let span = min(max(cell.colspan, TableCell.minColspan), TableCell.maxColspan)
            if col >= position && col < position + span { return index }
            position += span
        }
        return nil
    }

    // A colspan cell covering the column wouldn't travel with it, so those
    // columns stay un-grabbable.
    func canMoveColumn(_ col: Int) -> Bool {
        for row in table.rows {
            guard let idx = cellIndex(containingColumn: col, in: row) else { continue }
            let span = min(max(row[idx].colspan, TableCell.minColspan), TableCell.maxColspan)
            if span > 1 { return false }
        }
        return true
    }

    // Width and focus travel with the column; cells are matched by grid
    // column, not array index, so colspan rows stay consistent.
    func moveColumn(from source: Int, to destination: Int, before: EditorSnapshot) {
        let count = table.columnCount
        let dest = min(max(destination, 0), count - 1)
        guard source >= 0, source < count, dest != source else { return }
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
        guard let f = focusedCell, let c = cell(row: f.row, col: f.column) else { return }
        performUndoable(c.isHeader ? "Make Body Cell" : "Make Header Cell") {
            self.table.rows[f.row][f.column].isHeader.toggle()
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    func setColspan(_ value: Int) {
        guard let f = focusedCell, let c = cell(row: f.row, col: f.column), c.colspan != value else { return }
        performUndoable("Set Column Span") {
            self.table.rows[f.row][f.column].colspan = value
            // The wider cell may still overflow the current height.
            self.growRowIfNeeded(f.row)
            self.flushToDocument()
            self.regenerateHTML()
        }
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

    func toggleBold() {
        applyTraitToggle(name: "Toggle Bold") { font, manager in
            let hasBold = manager.traits(of: font).contains(.boldFontMask)
            return manager.convert(font, toHaveTrait: hasBold ? .unboldFontMask : .boldFontMask)
        }
    }

    func toggleItalic() {
        applyTraitToggle(name: "Toggle Italic") { font, manager in
            let hasItalic = manager.traits(of: font).contains(.italicFontMask)
            return manager.convert(font, toHaveTrait: hasItalic ? .unitalicFontMask : .italicFontMask)
        }
    }

    // NSFont has no .weight/.symbolicTraits in this SDK and the trait-mask
    // types aren't nameable, so NSFontManager does the arithmetic.
    private func applyTraitToggle(name: String, _ transform: (NSFont, NSFontManager) -> NSFont) {
        guard let f = focusedCell, let c = cell(row: f.row, col: f.column) else { return }
        let range = c.selectionRange.length > 0 ? c.selectionRange : c.fullRange
        guard range.length > 0 else { return }
        performUndoable(name) {
            let mutable = NSMutableAttributedString(attributedString: c.content)
            let manager = NSFontManager.shared
            mutable.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                mutable.addAttribute(.font, value: transform(font, manager), range: subRange)
            }
            self.table.rows[f.row][f.column].content = mutable
            // Bolder/wider glyphs can push wrapped text to extra lines.
            self.growRowIfNeeded(f.row)
            self.flushToDocument()
            self.regenerateHTML()
        }
    }

    var isHeaderActive: Bool {
        guard let f = focusedCell, let c = cell(row: f.row, col: f.column) else { return false }
        return c.isHeader
    }

    // Toolbar toggles read "on" only when every character of the focused
    // selection (whole cell if none) already carries the trait.
    private func selectionHasTrait(_ trait: NSFontTraitMask) -> Bool {
        guard let f = focusedCell, let c = cell(row: f.row, col: f.column) else { return false }
        let range = c.selectionRange.length > 0 ? c.selectionRange : c.fullRange
        guard range.length > 0 else { return false }
        var all = true
        var sawRun = false
        c.content.enumerateAttribute(.font, in: range) { value, _, _ in
            sawRun = true
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            if !NSFontManager.shared.traits(of: font).contains(trait) { all = false }
        }
        return sawRun && all
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
    }

    func selectDocument(_ id: UUID) {
        guard id != selectedDocumentID, let doc = document(id: id) else { return }
        flushToDocument()
        loadDocument(doc)
    }

    func renameDocument(_ id: UUID, to newName: String) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        documents[idx].name = trimmed.isEmpty ? "Untitled Table" : trimmed
        if id == selectedDocumentID {
            table.name = documents[idx].name
        }
    }

    /// The copy lands directly below its source and becomes the selection; it
    /// is undoable as one step, like delete.
    func duplicateDocument(_ id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        closeTypingGroup()
        flushToDocument()
        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID

        let source = documents[idx]
        // Fresh cells and a fresh id: editing the copy must not touch the source.
        let copy = TableDocument(table: Table(rows: deepCopied(source.table.rows),
                                              name: uniqueTableName(source.name)),
                                 fileURL: nil)
        documents.insert(copy, at: idx + 1)
        loadDocument(copy)

        let afterDocuments = deepCopied(documents)
        let afterSelection = selectedDocumentID
        // loadDocument clears the undo stack, so the pair registers after it.
        registerDocumentUndo(name: "Duplicate \(source.name)",
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
    /// selection are snapshotted and restored as one step.
    func deleteDocument(_ id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        closeTypingGroup()
        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID
        let removedName = documents[idx].name
        let removedFileURL = documents[idx].fileURL

        documents.remove(at: idx)
        savedHTML.removeValue(forKey: id)
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
            if let next = documents.first {
                loadDocument(next)
            }
        }

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
        } else if let first = documents.first {
            loadDocument(first)
        } else {
            // Undo restored the zero-tables state.
            selectedDocumentID = nil
            focusedCell = nil
        }
    }

    func duplicateSelectedDocument() {
        if let id = selectedDocumentID { duplicateDocument(id) }
    }

    func deleteSelectedDocument() {
        if let id = selectedDocumentID { deleteDocument(id) }
    }

    func deleteDocument(at offsets: IndexSet) {
        let ids = offsets.compactMap { idx in idx < documents.count ? documents[idx].id : nil }
        for id in ids { deleteDocument(id) }
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
        templateDraftRows = deepCopied(source.rows)
        templateNameText = source.name
        showTemplatePrompt = true
    }

    func saveAsTemplate() {
        defer { showTemplatePrompt = false }
        let typed = templateNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        var table = Table(rows: templateDraftRows,
                          name: uniqueName(typed, avoiding: Set(templates.map(\.name))))
        table.normalize()
        var template = TableDocument(table: table, fileURL: nil)
        guard let url = Self.writeTemplate(template) else { return }
        template.fileURL = url
        templates.append(template)
        templateNameText = ""
    }

    /// A fresh document carrying the template's rows, named after the template
    /// and numbered if a table already owns that name.
    func newTable(fromTemplate template: TableDocument) {
        flushToDocument()
        var table = Table(rows: deepCopied(template.table.rows),
                          name: uniqueName(template.name, avoiding: Set(documents.map(\.name))))
        table.normalize()
        let doc = TableDocument(table: table, fileURL: nil)
        documents.append(doc)
        loadDocument(doc)
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
        focusedCell = GridCell(row: 0, column: 0)
        cellSelection = nil
        ensureSizing()
        // Fresh tables start at the default height; grow to fit their text.
        // (restore() deliberately does NOT do this: snapshot heights are exact.)
        refreshRowHeights()
        regenerateHTML()
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
        var position = 0
        for cell in table.rows[row] {
            let span = min(max(cell.colspan, TableCell.minColspan), TableCell.maxColspan)
            let width = cellWidth(startingAtCol: position, span: span)
            needed = max(needed, Self.requiredHeight(for: cell.content, width: width))
            position += span
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
        return columnWidths[col..<end].reduce(0, +)
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

    // Filenames derive from table names — no save panel; a renamed table's
    // file follows it.
    func saveAllDocuments() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.saveDirectory, withIntermediateDirectories: true)
        var taken = Set<String>()
        for idx in documents.indices {
            let url = Self.uniqueFileURL(for: documents[idx].name, taken: &taken)
            let html = HTMLGenerator.html(for: documents[idx].table)
            if documents[idx].fileURL == url, savedHTML[documents[idx].id] == html { continue }
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Failed to save table: \(error)")
                continue
            }
            if let old = documents[idx].fileURL, old != url {
                try? fm.removeItem(at: old)
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
    // runs collapse. Legacy "----.html" files came from the old inverted-set
    // sanitizer.
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

    // Everything the user ever saved returns at launch from the save directory.
    private static func loadStoredDocuments() -> [TableDocument] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: saveDirectory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "html" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let html = try? String(contentsOf: url, encoding: .utf8) else {
                    NSLog("Skipping unreadable table file: \(url.path)")
                    return nil
                }
                let rawName = url.deletingPathExtension().lastPathComponent
                // Legacy saves were named "----.html" (the old broken
                // sanitizer); surface those as "Untitled Table".
                let name = Self.sanitizedFileName(rawName) == "Untitled Table" ? "Untitled Table" : rawName
                var table = Table(rows: HTMLParser.parse(html), name: name)
                table.normalize()
                return TableDocument(table: table, fileURL: url)
            }
    }

    func copyHTMLToClipboard() {
        closeTypingGroup()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(htmlText, forType: .string)
    }

    // MARK: - Cell copy / paste

    /// A cell's array index plus the visual columns it occupies; mirrors the
    /// grid's own slot layout so copy and selection agree on colspan.
    private struct RowSlot {
        let index: Int
        let startCol: Int
        let span: Int
    }

    private func rowSlots(for row: [TableCell]) -> [RowSlot] {
        var slots: [RowSlot] = []
        var position = 0
        for (index, cell) in row.enumerated() {
            let span = min(max(cell.colspan, TableCell.minColspan), TableCell.maxColspan)
            slots.append(RowSlot(index: index, startCol: position, span: span))
            position += span
        }
        return slots
    }

    /// The selected rectangle as its own Table: slot colspans clipped to the
    /// column window, rows padded rectangular.
    private func subtable(of sel: VisualCellRange) -> Table {
        var rows: [[TableCell]] = []
        for row in sel.rowStart...sel.rowEnd where table.rows.indices.contains(row) {
            var out: [TableCell] = []
            for slot in rowSlots(for: table.rows[row])
            where sel.intersects(row: row, startCol: slot.startCol, span: slot.span) {
                let lo = max(slot.startCol, sel.colStart)
                let hi = min(slot.startCol + slot.span - 1, sel.colEnd)
                guard lo <= hi else { continue }
                var cell = table.rows[row][slot.index]
                cell.colspan = hi - lo + 1
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
    func pasteAsNewTable() {        let pasteboard = NSPasteboard.general
        guard let source = pasteboard.string(forType: .html) ?? pasteboard.string(forType: .string),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let rows = HTMLParser.parse(source)
        guard !rows.isEmpty else { return }
        closeTypingGroup()
        flushToDocument()
        let beforeDocuments = deepCopied(documents)
        let beforeSelection = selectedDocumentID

        var table = Table(rows: rows, name: uniquePastedName())
        table.normalize()
        let doc = TableDocument(table: table, fileURL: nil)
        documents.append(doc)
        loadDocument(doc)

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

    /// ⌘⌫ means "delete the table" only with no caret; a disabled menu item
    /// still swallows its chord, so the keystroke goes back to the text as the
    /// paragraph delete it names. Live state, not the published flag.
    func deleteTableChordPressed() {
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
                var table = Table(rows: HTMLParser.parse(html),
                                  name: url.deletingPathExtension().lastPathComponent)
                table.normalize()
                return TableDocument(table: table, fileURL: url)
            }
    }

    // Headless harnesses set this: NSHomeDirectory() ignores $HOME for a bare
    // executable, so an env redirect cannot sandbox the library.
    static var saveDirectoryOverride: URL?

    static var saveDirectory: URL {
        if let override = saveDirectoryOverride { return override }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return base.appendingPathComponent("Running the Table", isDirectory: true)
    }
}
