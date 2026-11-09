import AppKit

struct TableCell {
    var content: NSAttributedString
    var colspan: Int
    var isHeader: Bool
    /// Last known selection inside this cell; the target of formatting commands.
    var selectionRange: NSRange

    init(content: NSAttributedString = NSAttributedString(string: ""),
         colspan: Int = 1,
         isHeader: Bool = false,
         selectionRange: NSRange = NSRange(location: 0, length: 0)) {
        self.content = content
        self.colspan = min(max(colspan, TableCell.minColspan), TableCell.maxColspan)
        self.isHeader = isHeader
        self.selectionRange = selectionRange
    }

    static let minColspan = 1
    static let maxColspan = 6

    var plainString: String { content.string }

    var fullRange: NSRange { NSRange(location: 0, length: content.length) }
}
