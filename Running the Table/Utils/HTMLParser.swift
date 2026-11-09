import AppKit

enum HTMLParser {
    // Content without a <table> tag is read as plain text: newlines make
    // rows, tabs make cells.
    static func parse(_ html: String) -> [[TableCell]] {
        guard html.range(of: "<table", options: .caseInsensitive) != nil else {
            return parsePlainText(html)
        }

        var rows: [[TableCell]] = []
        for rowMatch in matches("(?is)<tr[^>]*>(.*?)</tr>", html) {
            let rowInner = extracted(rowMatch, group: 1, from: html)
            var cells: [TableCell] = []
            for cellMatch in matches("(?is)<(t[dh])\\b([^>]*)>(.*?)</\\1>", rowInner) {
                let tag = extracted(cellMatch, group: 1, from: rowInner).lowercased()
                let attributes = extracted(cellMatch, group: 2, from: rowInner)
                let inner = extracted(cellMatch, group: 3, from: rowInner)
                let colspan = firstInt(in: attributes, attribute: "colspan") ?? 1
                cells.append(TableCell(
                    content: attributed(fromFragment: inner),
                    colspan: colspan,
                    isHeader: tag == "th"
                ))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows.isEmpty ? [[TableCell()]] : rows
    }

    private static func parsePlainText(_ text: String) -> [[TableCell]] {
        let decoded = decodeEntities(stripTags(text))
        let lines = decoded.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return [[TableCell()]] }
        return lines.map { line in
            line.components(separatedBy: "\t").map { piece in
                TableCell(content: plainAttributed(piece.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    // Cell interior → rich text; honors b/i/strong/em/a/br, ignores the rest.
    static func attributed(fromFragment fragment: String) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        guard let tagRegex = try? NSRegularExpression(pattern: "(?is)<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>") else {
            result.append(plainAttributed(decodeEntities(stripTags(fragment))))
            return result
        }

        let ns = fragment as NSString
        var bold = false
        var italic = false
        var link: URL?
        var lastEnd = 0

        for match in tagRegex.matches(in: fragment, range: NSRange(location: 0, length: ns.length)) {
            let gap = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if gap.length > 0 {
                let text = decodeEntities(ns.substring(with: gap))
                result.append(NSAttributedString(string: text,
                                                 attributes: cellAttributes(bold: bold, italic: italic, link: link)))
            }
            lastEnd = match.range.location + match.range.length

            let closing = ns.substring(with: match.range(at: 1)) == "/"
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            let rawAttributes = ns.substring(with: match.range(at: 3))

            switch (name, closing) {
            case ("b", false), ("strong", false): bold = true
            case ("b", true), ("strong", true): bold = false
            case ("i", false), ("em", false): italic = true
            case ("i", true), ("em", true): italic = false
            case ("br", _):
                result.append(NSAttributedString(string: "\n",
                                                 attributes: cellAttributes(bold: bold, italic: italic, link: link)))
            case ("a", false):
                link = extractHref(rawAttributes)
            case ("a", true):
                link = nil
            default:
                break // ignore all other tags (spans, divs, ...)
            }
        }

        if lastEnd < ns.length {
            let text = decodeEntities(ns.substring(from: lastEnd))
            result.append(NSAttributedString(string: text,
                                             attributes: cellAttributes(bold: bold, italic: italic, link: link)))
        }
        return result
    }

    private static func cellFont(bold: Bool, italic: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: 13)
        let manager = NSFontManager.shared
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private static func cellAttributes(bold: Bool, italic: Bool, link: URL?) -> [NSAttributedString.Key: Any] {
        // Explicit foreground color: text lacking it renders black regardless
        // of textColor — invisible in dark mode. labelColor adapts.
        var attrs: [NSAttributedString.Key: Any] = [
            .font: cellFont(bold: bold, italic: italic),
            .foregroundColor: NSColor.labelColor
        ]
        if let link { attrs[.link] = link }
        return attrs
    }

    static func plainAttributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: cellAttributes(bold: false, italic: false, link: nil))
    }

    static func decodeEntities(_ string: String) -> String {
        var s = string
        // Decode &amp; last so double-encoded entities do not resolve early.
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&apos;", with: "'")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s
    }

    static func stripTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<[^>]*>") else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: "")
    }

    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    }

    private static func extracted(_ result: NSTextCheckingResult, group index: Int, from text: String) -> String {
        let ns = text as NSString
        guard index < result.numberOfRanges, result.range(at: index).location != NSNotFound else { return "" }
        return ns.substring(with: result.range(at: index))
    }

    private static func firstInt(in text: String, attribute name: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\b\(name)\\s*=\\s*[\"']?(\\d+)") else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    private static func extractHref(_ attributeText: String) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        ) else { return nil }
        let ns = attributeText as NSString
        guard let match = regex.firstMatch(in: attributeText,
                                           range: NSRange(location: 0, length: ns.length)) else { return nil }
        for groupIndex in 1...3 {
            let r = match.range(at: groupIndex)
            if r.location != NSNotFound {
                let raw = decodeEntities(ns.substring(with: r))
                if let url = URL(string: raw) { return url }
            }
        }
        return nil
    }
}
