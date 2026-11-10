import Foundation

// fileURL is nil until the first save.
struct TableDocument: Identifiable {
    var table: Table
    var fileURL: URL?
    // Editor-only layout, in-memory like the undo stack: switching tables
    // must not inherit another table's resized widths and heights.
    var columnWidths: [CGFloat] = []
    var rowHeights: [CGFloat] = []

    var id: UUID { table.id }

    var name: String {
        get { table.name }
        set { table.name = newValue }
    }

    static func new(name: String) -> TableDocument {
        var table = Table.new()
        table.name = name
        return TableDocument(table: table, fileURL: nil)
    }
}
