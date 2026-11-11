import Foundation

/// Where a row lives in HTML's row-section anatomy; export groups rows by it.
enum RowSection: String {
    case head, body, foot

    /// Label for the Row Section menu's radio items.
    var menuTitle: String {
        switch self {
        case .head: return "Header"
        case .body: return "Body"
        case .foot: return "Footer"
        }
    }
}

/// One name/value pair as authored. Table-level only (the attributes sheet
/// edits those); cells and rows carry verbatim attribute text instead.
struct HTMLAttribute: Equatable {
    var name: String
    var value: String
}

/// One table row plus the markup the cell grid cannot carry: verbatim row
/// attributes and section membership. The collection conformance keeps the
/// rows[row][col] call sites compiling unchanged.
struct TableRow {
    var cells: [TableCell]
    var rawAttributes: String = ""
    var section: RowSection = .body

    init(cells: [TableCell] = [], rawAttributes: String = "", section: RowSection = .body) {
        self.cells = cells
        self.rawAttributes = rawAttributes
        self.section = section
    }

    /// A row earns its <thead> by being nothing but header cells.
    var allHeaders: Bool { !cells.isEmpty && cells.allSatisfy(\.isHeader) }
    func deepCopy() -> TableRow {
        var copy = self
        copy.cells = cells.map { $0.deepCopy() }
        return copy
    }
}

extension TableRow: Collection {
    var startIndex: Int { cells.startIndex }
    var endIndex: Int { cells.endIndex }
    subscript(position: Int) -> TableCell {
        get { cells[position] }
        set { cells[position] = newValue }
    }
    func index(after i: Int) -> Int { cells.index(after: i) }
}

extension TableRow: MutableCollection, RangeReplaceableCollection {
    init() { cells = [] }
    // The protocol's requirement is Sequence-broad; Array's own witness is
    // Collection-narrow, so materialize before delegating.
    mutating func replaceSubrange<C: Sequence>(_ subrange: Range<Int>, with newElements: C)
        where C.Element == TableCell {
        cells.replaceSubrange(subrange, with: Array(newElements))
    }
}
