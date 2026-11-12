import AppKit

struct TableCell {
    var content: NSAttributedString
    var colspan: Int
    var rowspan: Int
    var isHeader: Bool
    /// Last known selection inside this cell; the target of formatting commands.
    var selectionRange: NSRange
    /// Text alignment of the cell's content; the model's own attribute that
    /// rides in the cell's style attribute on export.
    var alignment: NSTextAlignment = .left
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
         alignment: NSTextAlignment = .left,
         selectionRange: NSRange = NSRange(location: 0, length: 0),
         rawAttributes: String = "",
         rawInnerHTML: String? = nil) {
        self.content = content
        self.colspan = min(max(colspan, TableCell.minColspan), TableCell.maxColspan)
        self.rowspan = min(max(rowspan, TableCell.minRowspan), TableCell.maxRowspan)
        self.isHeader = isHeader
        self.alignment = alignment
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

/// Toolbar labels for the cell alignment options.
extension NSTextAlignment {
    var iconName: String {
        switch self {
        case .left: return "text.justify.left"
        case .center: return "text.justify"
        case .right: return "text.justify.right"
        default: return "text.justify.left"
        }
    }

    var menuTitle: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        default: return "Left"
        }
    }

    /// The HTML spelling of the alignment for a style attribute.
    var htmlName: String {
        switch self {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        default: return "left"
        }
    }
}
