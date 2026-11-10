import AppKit

struct Table {
    var rows: [TableRow]
    var name: String
    let id: UUID

    // Pass-through markup the grid cannot show but the file must keep.
    /// Caption text; nil means the table has none.
    var caption: NSAttributedString?
    /// Verbatim caption interior while unedited (wins over `caption`).
    var captionRaw: String?
    /// Parsed table-level attributes minus data-table-name, in author order.
    var attributes: [HTMLAttribute] = []
    /// Verbatim <colgroup>/<col> blocks, emitted before the rows.
    var columnMarkup: [String] = []
    /// Everything before <table> and after </table>, byte-exact: page
    /// boilerplate, style blocks, even extra tables survive WYSIWYG edits.
    var sourcePrefix: String = ""
    var sourceSuffix: String = ""
    /// Parse notes for markup that could not be honored; transient (never
    /// exported) but travels with the loaded table to reach the HTML pane.
    var diagnostics: [String] = []

    init(rows: [TableRow], name: String = "Untitled Table", id: UUID = UUID()) {
        self.rows = rows
        self.name = name
        self.id = id
    }

    init(rows: [[TableCell]], name: String = "Untitled Table", id: UUID = UUID()) {
        self.rows = rows.map { TableRow(cells: $0) }
        self.name = name
        self.id = id
    }

    static func new() -> Table {
        Table(rows: [[TableCell()]])
    }

    var rowCount: Int { rows.count }

    /// Visual column count: cells can cover several columns each, and a
    /// rowspan lets later rows cover fewer.
    var columnCount: Int {
        rows.map { row in row.reduce(0) { $0 + Self.clampedSpan($1.colspan) } }.max() ?? 0
    }

    static func clampedSpan(_ value: Int) -> Int {
        min(max(value, TableCell.minColspan), TableCell.maxColspan)
    }

    static func clampedRowSpan(_ value: Int) -> Int {
        min(max(value, TableCell.minRowspan), TableCell.maxRowspan)
    }

    /// One cell's visual footprint: where it starts and how many columns and
    /// rows it covers. Rowskip-aware: startCol accounts for columns already
    /// claimed by rowspans from above.
    struct CellPlacement {
        let cellIndex: Int
        let startCol: Int
        let colSpan: Int
        let rowSpan: Int
    }

    /// Top-down grid layout: each row's own cells with their visual
    /// footprints, plus a map of columns a row cannot use because a cell
    /// originating in a row above still covers them (occupancy() also marks
    /// each cell's own footprint, so it can't serve as that map).
    private func gridScan() -> (slots: [[CellPlacement]], reserved: [[Bool]]) {
        let cols = max(columnCount, 1)
        var reserved = Array(repeating: Array(repeating: false, count: cols), count: rows.count)
        var out: [[CellPlacement]] = []
        for row in rows.indices {
            var slots: [CellPlacement] = []
            var col = 0
            for (index, cell) in rows[row].cells.enumerated() {
                while col < cols && reserved[row][col] { col += 1 }
                guard col < cols else { break }
                let w = Self.clampedSpan(cell.colspan)
                let h = Self.clampedRowSpan(cell.rowspan)
                slots.append(CellPlacement(cellIndex: index, startCol: col, colSpan: w, rowSpan: h))
                for dr in 1..<h where row + dr < rows.count {
                    for dc in 0..<w where col + dc < cols { reserved[row + dr][col + dc] = true }
                }
                col += w
            }
            out.append(slots)
        }
        return (out, reserved)
    }

    /// Each row's own cells with their visual footprints, in array order.
    func placements() -> [[CellPlacement]] { gridScan().slots }

    /// The cell visually covering grid position (row, col), which may
    /// originate in a row above via rowspan.
    func cellCovering(row: Int, col: Int) -> (row: Int, cell: Int)? {
        let slots = placements()
        guard row >= 0, row < slots.count else { return nil }
        for origin in 0...row {
            for p in slots[origin] where p.startCol <= col && col < p.startCol + p.colSpan {
                if origin + p.rowSpan > row { return (origin, p.cellIndex) }
            }
        }
        return nil
    }

    /// True when any merge (colspan or rowspan) touches the visual column,
    /// which is what makes a column unsafe to move or delete wholesale.
    func columnHasMerge(_ col: Int) -> Bool {
        for slots in placements() {
            for p in slots where p.startCol <= col && col < p.startCol + p.colSpan {
                if p.colSpan > 1 || p.rowSpan > 1 { return true }
            }
        }
        return false
    }

    /// True when any rowspan intersects the inclusive row band; moving or
    /// deleting rows inside that band would tear the merge apart.
    func rowspanCrosses(rows lo: Int, _ hi: Int) -> Bool {
        for (origin, slots) in placements().enumerated() {
            for p in slots where p.rowSpan > 1 && origin <= hi && origin + p.rowSpan - 1 >= lo {
                return true
            }
        }
        return false
    }

    /// True when a rowspan starts on one side of the row band and ends on
    /// the other: shifting rows wholly inside the band would tear it apart,
    /// while merges fully inside travel intact.
    func rowspanSplitsBand(_ lo: Int, _ hi: Int) -> Bool {
        for (origin, slots) in placements().enumerated() {
            for p in slots where p.rowSpan > 1 {
                let end = origin + p.rowSpan - 1
                if (origin < lo && end >= lo) || (origin <= hi && end > hi) { return true }
            }
        }
        return false
    }

    /// Column-axis twin: true when any merge straddles the column band's
    /// edge, so shifting columns inside the band would misalign it.
    func colspanSplitsBand(_ lo: Int, _ hi: Int) -> Bool {
        for slots in placements() {
            for p in slots where p.colSpan > 1 || p.rowSpan > 1 {
                let end = p.startCol + p.colSpan - 1
                if (p.startCol < lo && end >= lo) || (p.startCol <= hi && end > hi) { return true }
            }
        }
        return false
    }

    /// Per-row occupancy: true where a cell originating at or above this row
    /// (via rowspan) already covers the visual column.
    func occupancy() -> [[Bool]] {
        let cols = max(columnCount, 1)
        var taken = Array(repeating: Array(repeating: false, count: cols), count: rows.count)
        for row in rows.indices {
            var col = 0
            for cell in rows[row].cells {
                while col < cols && taken[row][col] { col += 1 }
                guard col < cols else { break }
                let w = Self.clampedSpan(cell.colspan)
                let h = Self.clampedRowSpan(cell.rowspan)
                for dr in 0..<h where row + dr < rows.count {
                    for dc in 0..<w where col + dc < cols { taken[row + dr][col + dc] = true }
                }
                col += w
            }
        }
        return taken
    }

    /// Pad/trim rows so every row visually spans the full grid; call after
    /// every add/remove row-or-column operation. Cells blocked in by rowspans
    /// count toward a row's coverage, so those rows need fewer of their own.
    mutating func normalize() {
        if rows.isEmpty { rows = [TableRow(cells: [TableCell()])] }
        let target = columnCount
        guard target > 0 else { return }
        for row in rows.indices {
            var taken = occupancy()
            var reserved = gridScan().reserved
            while filled(ofRow: row, taken: taken, target: target) < target {
                rows[row].cells.append(TableCell())
                taken = occupancy()
                reserved = gridScan().reserved
            }
            // Truncating can shrink a rowspan's blocked columns below, which
            // the top-down pass repads when it reaches those rows. A row can
            // also outlive its cells' columns: an inserted row of full width
            // under a rowspan has one cell too many to place.
            while !rows[row].cells.isEmpty,
                  filled(ofRow: row, taken: taken, target: target) > target
                      || unplacedCellCount(ofRow: row, reserved: reserved) > 0 {
                rows[row].cells.removeLast()
                taken = occupancy()
                reserved = gridScan().reserved
            }
        }
    }

    private func filled(ofRow row: Int, taken: [[Bool]], target: Int) -> Int {
        taken[row].prefix(target).filter { $0 }.count
    }

    /// Cells that never reach a visual column because rowspans above pushed
    /// the row past the grid's right edge; they render nowhere and must go.
    private func unplacedCellCount(ofRow row: Int, reserved: [[Bool]]) -> Int {
        let cols = max(columnCount, 1)
        var col = 0
        var placed = 0
        for cell in rows[row].cells {
            while col < cols && reserved[row][col] { col += 1 }
            guard col < cols else { break }
            col += Self.clampedSpan(cell.colspan)
            placed += 1
        }
        return rows[row].cells.count - placed
    }

    func isValid(row: Int, col: Int) -> Bool {
        row >= 0 && row < rows.count && col >= 0 && rows[row].cells.indices.contains(col)
    }

    /// Snapshot copy with fresh attributed strings throughout; pass an id to
    /// clone as a distinct table (duplicates), otherwise the id is kept.
    func deepCopied(id newID: UUID? = nil) -> Table {
        var copy = Table(rows: rows.map { $0.deepCopy() }, name: name, id: newID ?? id)
        copy.caption = caption.map { NSAttributedString(attributedString: $0) }
        copy.captionRaw = captionRaw
        copy.attributes = attributes
        copy.columnMarkup = columnMarkup
        copy.sourcePrefix = sourcePrefix
        copy.sourceSuffix = sourceSuffix
        copy.diagnostics = diagnostics
        return copy
    }
}

extension Table {
    /// A table loaded from parsed markup, pass-through fields and all.
    /// Callers replacing a live table pass its id: document identity is
    /// derived from table.id, so a fresh UUID would orphan the document.
    static func loaded(from parsed: ParsedTable, name: String, id: UUID = UUID()) -> Table {
        var table = Table(rows: parsed.rows, name: name, id: id)
        table.caption = parsed.caption
        table.captionRaw = parsed.captionRaw
        table.attributes = parsed.attributes
        table.columnMarkup = parsed.columnMarkup
        table.sourcePrefix = parsed.sourcePrefix
        table.sourceSuffix = parsed.sourceSuffix
        table.diagnostics = parsed.diagnostics
        table.normalize()
        return table
    }
}
