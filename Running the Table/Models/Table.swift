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
                let h = min(max(cell.rowspan, TableCell.minRowspan), TableCell.maxRowspan)
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
            while filled(ofRow: row, taken: taken, target: target) < target {
                rows[row].cells.append(TableCell())
                taken = occupancy()
            }
            // Truncating can shrink a rowspan's blocked columns below, which
            // the top-down pass repads when it reaches those rows.
            while filled(ofRow: row, taken: taken, target: target) > target,
                  !rows[row].cells.isEmpty {
                rows[row].cells.removeLast()
                taken = occupancy()
            }
        }
    }

    private func filled(ofRow row: Int, taken: [[Bool]], target: Int) -> Int {
        taken[row].prefix(target).filter { $0 }.count
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
    static func loaded(from parsed: ParsedTable, name: String) -> Table {
        var table = Table(rows: parsed.rows, name: name)
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
