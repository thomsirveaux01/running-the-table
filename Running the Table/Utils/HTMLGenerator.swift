import AppKit

enum HTMLGenerator {
    // The style attribute, wherever it sits in the cell's attribute text.
    private static let styleAttributePattern =
        try! NSRegularExpression(pattern: "(?i)style\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")

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
                    // Alignment is the model's own: it rides in the cell's style
                    // attribute, which the parser stripped of the declaration.
                    let attrs = cell.alignment != .left
                        ? Self.mergeAlignment(cell.rawAttributes, alignment: cell.alignment)
                        : cell.rawAttributes
                    if !attrs.isEmpty { cellAttrs += " " + attrs }
                    // Scope rides the row section: a head row's <th> is a
                    // column header, any other <th> is a row header.
                    if table.accessibilityScope && cell.isHeader {
                        cellAttrs += " scope=\"\(row.section == .head ? "col" : "row")\""
                    }
                    // Empty cells inside a merged region need SR-only text so
                    // screen readers do not read them as silent blanks.
                    if table.accessibilitySRText,
                       cell.content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       cell.colspan > 1 || cell.rowspan > 1 {
                        cellAttrs += " aria-label=\"Empty cell\""
                    }
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

    /// The model owns the cell's text-align; the author's declarations ride
    /// verbatim in the attribute text, so the declaration is merged into the
    /// existing style attribute (or created when the author left it out).
    private static func mergeAlignment(_ attrs: String, alignment: NSTextAlignment) -> String {
        guard alignment != .left else { return attrs }
        let value = alignment.htmlName
        let ns = attrs as NSString
        guard let styleMatch = styleAttributePattern.firstMatch(in: attrs,
                                                                range: NSRange(location: 0, length: ns.length)) else {
            return attrs.isEmpty ? "style=\"text-align: \(value)\"" : attrs + " style=\"text-align: \(value)\""
        }
        let styleValue = styleValue(from: styleMatch, in: attrs)
        let updated = styleValue + (styleValue.isEmpty ? "" : ";") + "text-align: \(value)"
        let before = ns.substring(with: NSRange(location: 0, length: styleMatch.range.location))
        let after = ns.substring(with: NSRange(location: styleMatch.range.location + styleMatch.range.length,
                                              length: ns.length - styleMatch.range.location - styleMatch.range.length))
        return before + "style=\"\(updated)\"" + after
    }

    /// The value of a style attribute in an attribute string, unquoted and
    /// empty when there is none.
    private static func styleValue(from match: NSTextCheckingResult, in text: String) -> String {
        let ns = text as NSString
        for groupIndex in 1...3 {
            let range = match.range(at: groupIndex)
            guard range.location != NSNotFound else { continue }
            let value = ns.substring(with: range)
            if value.count >= 2, value.first == value.last, "\"'".contains(value.first!) {
                return String(value.dropFirst().dropLast())
            }
            return value
        }
        return ""
    }
}
