import AppKit

struct TableCell {
    var content: NSAttributedString
    var colspan: Int
    var rowspan: Int
    var isHeader: Bool
    /// Last known selection inside this cell; the target of formatting commands.
    var selectionRange: NSRange
    /// Verbatim attribute text as parsed, minus colspan/rowspan (which the
    /// model owns); re-emitted untouched so unedited cells keep style, scope,
    /// class and anything else the grid cannot represent.
    var rawAttributes: String = ""
    /// Verbatim cell interior as parsed. The first content edit clears it,
    /// making the attributed content the source of truth from then on.
    var rawInnerHTML: String?

    init(content: NSAttributedString = NSAttributedString(string: ""),
         colspan: Int = 1,
         rowspan: Int = 1,
         isHeader: Bool = false,
         selectionRange: NSRange = NSRange(location: 0, length: 0),
         rawAttributes: String = "",
         rawInnerHTML: String? = nil) {
        self.content = content
        self.colspan = min(max(colspan, TableCell.minColspan), TableCell.maxColspan)
        self.rowspan = min(max(rowspan, TableCell.minRowspan), TableCell.maxRowspan)
        self.isHeader = isHeader
        self.selectionRange = selectionRange
        self.rawAttributes = rawAttributes
        self.rawInnerHTML = rawInnerHTML
    }

    static let minColspan = 1
    static let maxColspan = 6
    static let minRowspan = 1
    static let maxRowspan = 6

    var plainString: String { content.string }

    var fullRange: NSRange { NSRange(location: 0, length: content.length) }

    /// Snapshot copy with a fresh attributed string; undo captures must not
    /// share storage with live cells.
    func deepCopy() -> TableCell {
        var copy = self
        copy.content = NSAttributedString(attributedString: content)
        return copy
    }
}
