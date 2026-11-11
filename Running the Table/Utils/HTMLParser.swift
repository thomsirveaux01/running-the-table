import AppKit

/// Everything one HTML source document carries: the editable grid plus the
/// markup around and inside it that the grid cannot show but a re-export must
/// keep byte-faithful.
struct ParsedTable {
    var rows: [TableRow] = []
    var caption: NSAttributedString?
    var captionRaw: String?
    var attributes: [HTMLAttribute] = []
    /// Title from a legacy `data-table-name` attribute, if present; used
    /// only to seed the app's title store, never shown as a user attribute.
    var legacyName: String?
    var columnMarkup: [String] = []
    var sourcePrefix = ""
    var sourceSuffix = ""
    /// Human-readable notes on markup that was dropped or left unclosed;
    /// surfaced in the HTML pane so invalid hand edits do not vanish silently.
    var diagnostics: [String] = []
}

enum HTMLParser {
    // Precompiled constant patterns; try! only trips on a programmer typo.
    private static let tagPattern = try! NSRegularExpression(pattern: "(?is)<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>")
    private static let anyTagPattern = try! NSRegularExpression(pattern: "(?is)<[^>]*>")
    private static let hrefPattern = try! NSRegularExpression(pattern: "(?i)href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
    private static let entityPattern = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);")

    // MARK: - Tokens

    private struct Token {
        enum Kind { case open, close, text, comment, declaration }
        var kind: Kind
        var name = ""              // lowercased tag name; empty for text/comment
        var attributeText = ""
        var selfClosing = false
        var range: NSRange         // verbatim slice of the source
    }

    /// One-pass scanner. Attribute values may contain '>' (e.g. style="a>b"),
    /// so tag ends track quote state.
    private static func tokenize(_ source: String) -> [Token] {
        let ns = source as NSString
        let end = ns.length
        var tokens: [Token] = []
        var i = 0

        func char(_ at: Int) -> unichar { at < end ? ns.character(at: at) : 0 }
        func hasPrefix(_ s: String, at position: Int) -> Bool {
            ns.substring(with: NSRange(location: position, length: min(s.count, end - position))) == s
        }

        while i < end {
            var lt = i
            while lt < end, char(lt) != UInt16(ascii: "<") { lt += 1 }
            if lt > i {
                tokens.append(Token(kind: .text, range: NSRange(location: i, length: lt - i)))
            }
            if lt >= end { return tokens }

            if hasPrefix("<!--", at: lt) {
                var j = lt + 4
                while j < end, !hasPrefix("-->", at: j) { j += 1 }
                j = min(j + 3, end)
                tokens.append(Token(kind: .comment, range: NSRange(location: lt, length: j - lt)))
                i = j
                continue
            }
            if char(lt + 1) == UInt16(ascii: "!") || char(lt + 1) == UInt16(ascii: "?") {
                var j = lt + 2
                while j < end, char(j) != UInt16(ascii: ">") { j += 1 }
                j = min(j + 1, end)
                tokens.append(Token(kind: .declaration, range: NSRange(location: lt, length: j - lt)))
                i = j
                continue
            }

            var j = lt + 1
            let closing = char(j) == UInt16(ascii: "/")
            if closing { j += 1 }
            let nameStart = j
            while j < end, isNameChar(char(j), first: j == nameStart) { j += 1 }
            guard j > nameStart else {
                // A stray '<' is text.
                tokens.append(Token(kind: .text, range: NSRange(location: lt, length: 1)))
                i = lt + 1
                continue
            }
            let name = ns.substring(with: NSRange(location: nameStart, length: j - nameStart)).lowercased()

            // Scan to the unquoted '>'.
            var quote: unichar = 0
            var gt = j
            while gt < end {
                let c = char(gt)
                if quote != 0 {
                    if c == quote { quote = 0 }
                } else if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") {
                    quote = c
                } else if c == UInt16(ascii: ">") {
                    break
                }
                gt += 1
            }
            let tagEnd = min(gt + 1, end)
            var attrEnd = gt
            var selfClosing = false
            if gt > j, char(gt - 1) == UInt16(ascii: "/") {
                selfClosing = true
                attrEnd = gt - 1
            }
            let attributeText = ns.substring(with: NSRange(location: j, length: max(attrEnd - j, 0)))
            tokens.append(Token(kind: closing ? .close : .open, name: name,
                                attributeText: attributeText, selfClosing: selfClosing,
                                range: NSRange(location: lt, length: tagEnd - lt)))
            i = tagEnd
        }
        return tokens
    }

    private static func isNameChar(_ c: unichar, first: Bool) -> Bool {
        (c >= UInt16(ascii: "a") && c <= UInt16(ascii: "z"))
            || (c >= UInt16(ascii: "A") && c <= UInt16(ascii: "Z"))
            || (!first && c >= UInt16(ascii: "0") && c <= UInt16(ascii: "9"))
    }

    /// Attributes with their source ranges, so the model can strip the ones
    /// it owns (colspan, rowspan) and re-emit the rest verbatim.
    private static func attributes(in text: String) -> [(pair: HTMLAttribute, range: NSRange)] {
        let ns = text as NSString
        let end = ns.length
        var out: [(HTMLAttribute, NSRange)] = []
        var i = 0
        func char(_ at: Int) -> unichar { at < end ? ns.character(at: at) : 0 }
        func isSpace(_ c: unichar) -> Bool {
            c == UInt16(ascii: " ") || c == UInt16(ascii: "\t") || c == UInt16(ascii: "\n") || c == UInt16(ascii: "\r")
        }
        while i < end {
            while i < end, isSpace(char(i)) { i += 1 }
            let nameStart = i
            while i < end, !isSpace(char(i)), char(i) != UInt16(ascii: "="), char(i) != UInt16(ascii: "/") { i += 1 }
            guard i > nameStart else { break }
            let name = ns.substring(with: NSRange(location: nameStart, length: i - nameStart)).lowercased()
            var value = ""
            var valueEnd = i
            var k = i
            while k < end, isSpace(char(k)) { k += 1 }
            if k < end, char(k) == UInt16(ascii: "=") {
                k += 1
                while k < end, isSpace(char(k)) { k += 1 }
                let quote = char(k)
                if quote == UInt16(ascii: "\"") || quote == UInt16(ascii: "'") {
                    k += 1
                    let vStart = k
                    while k < end, char(k) != quote { k += 1 }
                    value = ns.substring(with: NSRange(location: vStart, length: max(k - vStart, 0)))
                    valueEnd = min(k + 1, end)
                } else {
                    let vStart = k
                    while k < end, !isSpace(char(k)) { k += 1 }
                    value = ns.substring(with: NSRange(location: vStart, length: max(k - vStart, 0)))
                    valueEnd = k
                }
                i = valueEnd
            } else {
                value = ""  // boolean attribute; re-emitted name-only
            }
            out.append((HTMLAttribute(name: name, value: decodeEntities(value)),
                        NSRange(location: nameStart, length: valueEnd - nameStart)))
        }
        return out
    }

    /// Attribute text minus the named attributes, remaining bytes verbatim.
    private static func rawAttributes(in text: String, removing names: Set<String>) -> String {
        let removed = attributes(in: text).filter { names.contains($0.pair.name) }.map(\.range)
        guard !removed.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let ns = text as NSString
        var pieces: [String] = []
        var last = 0
        for r in removed.sorted(by: { $0.location < $1.location }) {
            pieces.append(ns.substring(with: NSRange(location: last, length: r.location - last)))
            last = r.location + r.length
        }
        pieces.append(ns.substring(from: last))
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intValue(_ attributes: [HTMLAttribute], _ name: String, default fallback: Int) -> Int {
        guard let raw = attributes.first(where: { $0.name == name })?.value,
              let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return fallback }
        return value
    }

    // MARK: - Table parsing

    static func parseTable(_ html: String) -> ParsedTable {
        let ns = html as NSString
        let tokens = tokenize(html)
        guard let open = tokens.firstIndex(where: { $0.kind == .open && $0.name == "table" }) else {
            var plain = ParsedTable()
            plain.rows = parsePlainText(html).map { TableRow(cells: $0) }
            return plain
        }

        var p = ParsedTable()
        p.sourcePrefix = ns.substring(to: tokens[open].range.location)
        let tableAttrs = attributes(in: tokens[open].attributeText).map(\.pair)
        // Seed the app's title store from any legacy data-table-name, then
        // drop it so it never resurfaces as a user attribute or gets re-emitted.
        p.legacyName = tableAttrs.first { $0.name == "data-table-name" }?.value
        p.attributes = tableAttrs.filter { $0.name != "data-table-name" }

        var i = open + 1
        var section: RowSection = .body
        var sawHead = false
        var droppedTextNoted = false
        var closedTable = false

        while i < tokens.count {
            let t = tokens[i]
            switch (t.kind, t.name) {
            case (.close, "table"):
                p.sourceSuffix += ns.substring(from: t.range.location + t.range.length)
                closedTable = true
                i = tokens.count
            case (.open, "table"):
                // A second top-level table (or a stray nested one) is not the
                // edited table; it lives on untouched in the suffix instead.
                let stop = closeIndex(tokens, from: i, name: "table").map { $0 + 1 } ?? tokens.count
                let blockEnd = stop < tokens.count ? tokens[stop].range.location : ns.length
                p.sourceSuffix += ns.substring(with: NSRange(location: t.range.location,
                                                             length: blockEnd - t.range.location))
                i = stop
            case (.open, "caption"):
                let innerStart = t.range.location + t.range.length
                if let end = closeIndex(tokens, from: i, name: "caption") {
                    let raw = ns.substring(with: NSRange(location: innerStart,
                                                         length: tokens[end].range.location - innerStart))
                    p.captionRaw = raw
                    p.caption = attributed(fromFragment: raw)
                    i = end + 1
                } else {
                    p.diagnostics.append("Caption is missing its </caption> tag.")
                    p.caption = NSAttributedString()
                    p.captionRaw = ""
                    i += 1
                }
            case (.open, "colgroup"), (.open, "col"):
                // </colgroup> is optional in HTML; the block ends at the
                // first tag that cannot belong to it.
                var j = i + 1
                while j < tokens.count, tokens[j].kind == .open,
                      tokens[j].name == "col" || tokens[j].name == "colgroup" { j += 1 }
                if t.name == "colgroup", let end = closeIndex(tokens, from: i, name: "colgroup") {
                    j = end + 1
                }
                let blockEnd = j < tokens.count ? tokens[j].range.location : ns.length
                // Drop the whitespace before the following tag: the generator
                // adds its own newline, and keeping both would grow the file
                // on every save.
                let block = ns.substring(with: NSRange(location: t.range.location,
                                                       length: blockEnd - t.range.location))
                p.columnMarkup.append(block.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
                i = j
            case (.open, "thead"): section = .head; sawHead = true; i += 1
            case (.open, "tbody"): section = .body; i += 1
            case (.open, "tfoot"): section = .foot; i += 1
            case (.close, "thead"), (.close, "tbody"), (.close, "tfoot"): section = .body; i += 1
            case (.open, "tr"):
                i = parseRow(tokens, at: i, ns: ns, section: section, into: &p)
            case (.open, "td"), (.open, "th"):
                p.diagnostics.append("A cell outside a <tr> was dropped.")
                i = skipCell(tokens, from: i)
            case (.text, _):
                if !ns.substring(with: t.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !droppedTextNoted {
                    p.diagnostics.append("Text sitting directly inside the table was dropped.")
                    droppedTextNoted = true
                }
                i += 1
            default:
                i += 1  // comments, stray closes, unsupported tags
            }
        }
        if !closedTable {
            p.diagnostics.append("Table is missing its </table> tag.")
        }
        // Legacy tables flag headers with plain <th> rows: when the author
        // never wrote a <thead>, treat leading all-header rows as the head.
        if !sawHead {
            for row in p.rows.indices {
                guard !p.rows[row].cells.isEmpty,
                      p.rows[row].cells.allSatisfy(\.isHeader) else { break }
                p.rows[row].section = .head
            }
        }
        if p.rows.isEmpty { p.rows = [TableRow(cells: [TableCell()])] }
        return p
    }

    /// Index of the matching same-name close tag, balanced against nested
    /// same-name opens; nil when the tag never closes.
    private static func closeIndex(_ tokens: [Token], from: Int, name: String) -> Int? {
        var depth = 0
        var j = from
        while j < tokens.count {
            if tokens[j].kind == .open, tokens[j].name == name { depth += 1 }
            if tokens[j].kind == .close, tokens[j].name == name {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    private static let cellStructuralNames: Set<String> = [
        "table", "tr", "td", "th", "tbody", "thead", "tfoot", "caption", "colgroup"
    ]

    @discardableResult
    private static func parseRow(_ tokens: [Token], at index: Int, ns: NSString,
                                 section: RowSection, into p: inout ParsedTable) -> Int {
        let t = tokens[index]
        var cells: [TableCell] = []
        var j = index + 1
        var ended = false
        while j < tokens.count {
            let u = tokens[j]
            if u.kind == .open, u.name == "tr" { ended = true; break }  // implicit end
            if u.kind == .close, u.name == "tr" { ended = true; j += 1; break }
            if u.kind == .close, ["table", "tbody", "thead", "tfoot"].contains(u.name) { ended = true; break }
            if u.kind == .open, ["table", "tbody", "thead", "tfoot", "caption"].contains(u.name) { ended = true; break }
            if u.kind == .open, u.name == "td" || u.name == "th" {
                j = parseCell(tokens, at: j, ns: ns, into: &cells, p: &p)
                continue
            }
            j += 1
        }
        // Only EOF leaves a row genuinely unclosed; the next <tr> or a
        // section/table close are spec-valid implicit ends.
        if !ended { p.diagnostics.append("A table row is missing its </tr> tag.") }
        // Empty rows are kept: a rowspan can leave a row with no cells of its
        // own, and dropping it would shrink the table on reload.
        p.rows.append(TableRow(cells: cells, rawAttributes: rowRaw(t), section: section))
        return j
    }

    private static func rowRaw(_ token: Token) -> String {
        token.attributeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses one cell. At nesting depth 0 (outside any nested table) the
    /// next cell, a row/section end tag, or another structural open all end
    /// this cell — HTML lets those stand in for </td>. Inside a nested
    /// table everything passes through untouched.
    private static func parseCell(_ tokens: [Token], at index: Int, ns: NSString,
                                  into cells: inout [TableCell], p: inout ParsedTable) -> Int {
        let t = tokens[index]
        let attrs = attributes(in: t.attributeText)
        let pairs = attrs.map(\.pair)
        let colspan = intValue(pairs, "colspan", default: 1)
        let rowspan = intValue(pairs, "rowspan", default: 1)
        let rawAttrs = rawAttributes(in: t.attributeText, removing: ["colspan", "rowspan"])

        var next = index + 1
        if t.selfClosing {
            cells.append(TableCell(content: NSAttributedString(), colspan: colspan, rowspan: rowspan,
                                   isHeader: t.name == "th", rawAttributes: rawAttrs, rawInnerHTML: ""))
            return next
        }
        let innerStart = t.range.location + t.range.length
        var nestedTables = 0
        var innerEnd: Int?
        while next < tokens.count {
            let u = tokens[next]
            let endsCell: Bool
            if u.kind == .open, u.name == "table" {
                nestedTables += 1
                endsCell = false
            } else if u.kind == .close, u.name == "table" {
                if nestedTables > 0 { nestedTables -= 1; endsCell = false } else { endsCell = true }
            } else if nestedTables == 0, u.name == "td" || u.name == "th" {
                endsCell = true
            } else if nestedTables == 0,
                      ["tr", "tbody", "thead", "tfoot", "caption", "colgroup"].contains(u.name) {
                endsCell = true
            } else {
                endsCell = false
            }
            if endsCell {
                innerEnd = u.range.location
                if u.kind == .close, u.name == t.name { next += 1 }  // only </td> is consumed
                break
            }
            next += 1
        }
        // Only EOF leaves a cell unclosed; implicit ends are valid HTML.
        if innerEnd == nil {
            p.diagnostics.append("A cell is missing its closing tag; its text was kept.")
        }
        let rawInner = ns.substring(with: NSRange(location: innerStart,
                                                  length: max((innerEnd ?? ns.length) - innerStart, 0)))
        cells.append(TableCell(content: attributed(fromFragment: rawInner),
                               colspan: colspan, rowspan: rowspan,
                               isHeader: t.name == "th", rawAttributes: rawAttrs,
                               rawInnerHTML: rawInner))
        return next
    }

    private static func skipCell(_ tokens: [Token], from: Int) -> Int {
        var j = from + 1
        var depth = 0
        while j < tokens.count {
            let u = tokens[j]
            if u.kind == .open, cellStructuralNames.contains(u.name) { depth += 1 }
            if u.kind == .close, u.name == "td" || u.name == "th" {
                if depth == 0 { return j + 1 }
                depth -= 1
            }
            if u.kind == .close, u.name == "table" { return j }
            j += 1
        }
        return j
    }

    // MARK: - Plain text

    // Content without a <table> tag is read as plain text: newlines make
    // rows, tabs make cells.
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

    // MARK: - Inline fragments

    // Cell interior → rich text; honors b/i/strong/em/a/br, ignores the rest.
    static func attributed(fromFragment fragment: String) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let ns = fragment as NSString
        var bold = false
        var italic = false
        var link: URL?
        var lastEnd = 0

        for match in tagPattern.matches(in: fragment, range: NSRange(location: 0, length: ns.length)) {
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
        var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
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

    // MARK: - Entities

    /// Named entities decoded on import; anything unknown (rare names, typos
    /// like "&amph;") survives verbatim rather than mangling the text. One
    /// regex pass means "&amp;lt;" decodes to "&lt;", never further.
    private static let entityNames: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "sbquo": "\u{201A}", "bdquo": "\u{201E}", "dagger": "†", "Dagger": "‡",
        "permil": "‰", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "times": "×",
        "divide": "÷", "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "deg": "°", "micro": "µ", "para": "¶", "sect": "§", "middot": "·",
        "laquo": "«", "raquo": "»", "bull": "•", "euro": "€", "pound": "£", "yen": "¥",
        "cent": "¢", "curren": "¤", "brvbar": "¦", "ordf": "ª", "ordm": "º",
        "not": "¬", "shy": "\u{AD}", "macr": "¯", "acute": "´", "cedil": "¸",
        "sup1": "¹", "sup2": "²", "sup3": "³", "iexcl": "¡", "iquest": "¿",
        "darr": "↓", "uarr": "↑", "larr": "←", "rarr": "→", "harr": "↔",
        "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞", "OElig": "Œ", "oelig": "œ",
        "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "circ": "ˆ", "tilde": "˜",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}",
    ]

    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        let ns = string as NSString
        var result = ""
        var last = 0
        for match in entityPattern.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            guard let bodyRange = Range(match.range(at: 1), in: string) else { continue }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let whole = ns.substring(with: match.range)
            let body = String(string[bodyRange])
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let scalarValue: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    scalarValue = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(digits)
                }
                if let v = scalarValue, let scalar = Unicode.Scalar(v), v != 0 {
                    result.append(Character(scalar))
                } else {
                    result += whole  // out of range: keep as written
                }
            } else if let mapped = entityNames[body] {
                result += mapped
            } else {
                result += whole
            }
        }
        result += ns.substring(from: last)
        return result
    }

    static func stripTags(_ text: String) -> String {
        let ns = text as NSString
        return anyTagPattern.stringByReplacingMatches(in: text,
                                                      range: NSRange(location: 0, length: ns.length),
                                                      withTemplate: "")
    }

    private static func extractHref(_ attributeText: String) -> URL? {
        let ns = attributeText as NSString
        guard let match = hrefPattern.firstMatch(in: attributeText,
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

private extension UInt16 {
    init(ascii: Unicode.Scalar) { self = UInt16(ascii.value) }
}
