import Foundation

struct Table {
    var rows: [[TableCell]]
    var name: String
    let id: UUID

    init(rows: [[TableCell]], name: String = "Untitled Table", id: UUID = UUID()) {
        self.rows = rows
        self.name = name
        self.id = id
    }

    static func new() -> Table {
        Table(rows: [[TableCell()]])
    }

    var rowCount: Int { rows.count }

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// Pad/trim rows so the table stays rectangular; call after every
    /// add/remove row-or-column operation.
    mutating func normalize() {
        if rows.isEmpty {
            rows = [[TableCell()]]
        }
        let target = columnCount
        for row in rows.indices {
            while rows[row].count < target { rows[row].append(TableCell()) }
            if rows[row].count > target { rows[row].removeSubrange(target..<rows[row].count) }
        }
    }

    func isValid(row: Int, col: Int) -> Bool {
        row >= 0 && row < rows.count && col >= 0 && col < rows[row].count
    }
}
