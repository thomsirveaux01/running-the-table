import AppKit

enum HTMLGenerator {
    static func html(for table: Table) -> String {
        var attrs = ""
        for attribute in table.attributes {
            attrs += " \(attribute.name)=\"\(escapeAttribute(attribute.value))\""
        }
        // The title lives in the app (see TableViewModel's title store);
        // nothing identifying is written into the HTML.
        var lines: [String] = ["<table\(attrs)>"]
        if let caption = table.caption {
            lines.append("  <caption>\(table.captionRaw ?? attributedToHTML(caption))</caption>")
        }
        lines.append(contentsOf: table.columnMarkup)

        for section in [RowSection.head, .body, .foot] {
            let rows = table.rows.filter { $0.section == section }
            guard !rows.isEmpty else { continue }
            let tag: String
            switch section {
            case .head: tag = "thead"
            case .body: tag = "tbody"
            case .foot: tag = "tfoot"
            }
            lines.append("<\(tag)>")
            for row in rows {
                let rowAttrs = row.rawAttributes.isEmpty ? "" : " \(row.rawAttributes)"
                lines.append("  <tr\(rowAttrs)>")
                for cell in row {
                    let tag = cell.isHeader ? "th" : "td"
                    var cellAttrs = ""
                    if cell.colspan > 1 { cellAttrs += " colspan=\"\(cell.colspan)\"" }
                    if cell.rowspan > 1 { cellAttrs += " rowspan=\"\(cell.rowspan)\"" }
                    if !cell.rawAttributes.isEmpty { cellAttrs += " " + cell.rawAttributes }
                    // Unedited cells re-emit their parsed interior byte-exact;
                    // content is only converted after the user touches it.
                    let inner = cell.rawInnerHTML ?? attributedToHTML(cell.content)
                    lines.append("    <\(tag)\(cellAttrs)>\(inner)</\(tag)>")
                }
                lines.append("  </tr>")
            }
            lines.append("</\(tag)>")
        }
        lines.append("</table>")
        return table.sourcePrefix + lines.joined(separator: "\n") + table.sourceSuffix
    }

    static func html(forCell cell: TableCell) -> String {
        cell.rawInnerHTML ?? attributedToHTML(cell.content)
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
