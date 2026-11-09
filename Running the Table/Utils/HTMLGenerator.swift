import AppKit

enum HTMLGenerator {
    static func html(for table: Table) -> String {
        var lines: [String] = ["<table>", "<tbody>"]
        for row in table.rows {
            lines.append("  <tr>")
            for cell in row {
                let tag = cell.isHeader ? "th" : "td"
                let colspan = cell.colspan > 1 ? " colspan=\"\(cell.colspan)\"" : ""
                lines.append("    <\(tag)\(colspan)>\(html(forCell: cell))</\(tag)>")
            }
            lines.append("  </tr>")
        }
        lines.append("</tbody>")
        lines.append("</table>")
        return lines.joined(separator: "\n")
    }

    static func html(forCell cell: TableCell) -> String {
        attributedToHTML(cell.content)
    }

    static func attributedToHTML(_ text: NSAttributedString) -> String {
        guard text.length > 0 else { return "" }
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            var fragment = escapeHTML(String(text.attributedSubstring(from: range).string))
            // Hard line breaks become <br> so multi-line cells stay readable.
            fragment = fragment.replacingOccurrences(of: "\n", with: "<br>")
            if let font = attrs[.font] as? NSFont {
                // NSFontTraits is not nameable in this SDK; infer the type.
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { fragment = "<strong>\(fragment)</strong>" }
                if traits.contains(.italicFontMask) { fragment = "<em>\(fragment)</em>" }
            }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? "\(link)"
                fragment = "<a href=\"\(escapeAttribute(url))\">\(fragment)</a>"
            }
            result += fragment
        }
        return result
    }

    static func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
              .replacingOccurrences(of: "<", with: "&lt;")
              .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ string: String) -> String {
        escapeHTML(string).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
