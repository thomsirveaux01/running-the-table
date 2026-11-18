import AppKit
import Foundation
import UniformTypeIdentifiers

// GFM pipe table import/export. The scanner finds top-level pipe tables (fence-, setext-,
// and HTML-block-aware) and turns each into standard <table> HTML for the existing parser.
enum MarkdownTable {

    /// One pipe table found in a file: the title to give it (the nearest preceding
    /// ATX heading, or nil for the caller's file-stem fallback) and standard <table> HTML.
    struct Found {
        let title: String?
        let html: String
    }

    // MARK: - Scanning

    /// Every top-level pipe table, in order. A table is a header line followed by a valid
    /// delimiter with a matching cell count; the body runs to the first line that can open its own block.
    static func tables(in text: String) -> [Found] {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var found: [Found] = []
        var lastHeading: String?
        var fence: (char: Character, length: Int)?
        var htmlBlock: HTMLBlockKind?

        var i = 0
        while i < lines.count {
            let line = lines[i]

            if let f = fence {
                if isFenceClose(line, char: f.char, length: f.length) { fence = nil }
                i += 1
                continue
            }
            if let block = htmlBlock {
                if htmlBlockEnds(block, on: line) { htmlBlock = nil }
                i += 1
                continue
            }
            if let open = fenceOpen(line) {
                fence = open
                i += 1
                continue
            }
            if let block = htmlBlockStart(line) {
                // The end condition is checked on the start line too, so
                // <!-- x --> and <!DOCTYPE html> close on their own line.
                if !htmlBlockEnds(block, on: line) { htmlBlock = block }
                i += 1
                continue
            }
            if let heading = atxHeading(line) {
                lastHeading = titleText(fromHeadingText: heading)
                i += 1
                continue
            }
            guard indentWidth(line) < 4,
                  i + 1 < lines.count,
                  indentWidth(lines[i + 1]) < 4,
                  let delim = delimiterInfo(lines[i + 1]) else {
                i += 1
                continue
            }
            let headerCells = splitRow(line)
            guard isRowLine(line), headerCells.count == delim.cellCount else { i += 1; continue }

            var end = i + 2
            while end < lines.count, isBodyRow(lines[end]) { end += 1 }
            found.append(Found(title: lastHeading,
                               html: buildHTML(header: line, delimiter: lines[i + 1],
                                               body: Array(lines[(i + 2)..<end]))))
            i = end
        }
        return found
    }

    // MARK: - Line classification

    /// Leading-space width for the block rules; a tab indents to column 4.
    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for c in line {
            if c == " " { width += 1 }
            else if c == "\t" { return 4 }
            else { break }
        }
        return width
    }

    /// A fenced code block opener: 3+ backticks or tildes; a backtick fence's
    /// info string may not contain a backtick.
    private static func fenceOpen(_ line: String) -> (char: Character, length: Int)? {
        guard indentWidth(line) < 4 else { return nil }
        let chars = Array(line.drop(while: { $0 == " " }))
        for fenceChar: Character in ["`", "~"] {
            var run = 0
            while run < chars.count, chars[run] == fenceChar { run += 1 }
            guard run >= 3 else { continue }
            if fenceChar == "`", chars[run...].contains("`") { continue }
            return (fenceChar, run)
        }
        return nil
    }

    /// A closing fence: only the fence character, at least as long as the opener, nothing else.
    private static func isFenceClose(_ line: String, char: Character, length: Int) -> Bool {
        guard indentWidth(line) < 4 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count >= length else { return false }
        return trimmed.allSatisfy { $0 == char }
    }

    /// The ATX heading's text with inline markers stripped, or nil; a closing
    /// sequence of #s preceded by whitespace is not content.
    private static func atxHeading(_ line: String) -> String? {
        guard indentWidth(line) < 4 else { return nil }
        let chars = Array(line.drop(while: { $0 == " " }))
        var run = 0
        while run < chars.count, chars[run] == "#" { run += 1 }
        guard (1...6).contains(run),
              run == chars.count || chars[run] == " " || chars[run] == "\t" else { return nil }
        var text = String(chars[run...]).trimmingCharacters(in: .whitespaces)
        if let lastSpace = text.lastIndex(where: { $0 == " " || $0 == "\t" }) {
            let tail = text[text.index(after: lastSpace)...]
            if !tail.isEmpty, tail.allSatisfy({ $0 == "#" }) {
                text = String(text[..<lastSpace])
            }
        }
        return text.isEmpty ? nil : text
    }

    // The GFM HTML block kinds and what ends each: type 1 runs to a line holding any
    // of the four closing tags, types 2-5 to their end markers, type 6 to a blank line.
    private enum HTMLBlockKind {
        case singleLine
        case untilBlank
        case untilMarker(String)
        case untilCloseTag
    }

    /// The type-6 block tag names (open or close); a line starting with one
    /// of these plus a space or > runs to a blank line.
    private static let blockTagNames: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
        "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section",
        "source", "title", "summary", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "track", "ul",
    ]

    // Type 7: exactly one complete tag then whitespace; two tags (<div></div>) stays a table row.
    private static let completeTagPattern = try! NSRegularExpression(
        pattern: "^</?[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[a-zA-Z_:][a-zA-Z0-9:._-]*"
            + "(?:[ \t]*=[ \t]*(?:\"[^\"]*\"|'[^']*'|[^ \t\r\n\u{0B}\u{0C}\"'=<>`]+))?[ \t]*)*"
            + "[ \t]*/?>[ \t]*$")

    /// An HTML block start (GFM types 1-7), in the scanner's precedence order;
    /// nil means the line is not a block start (and may be a table row).
    private static func htmlBlockStart(_ line: String) -> HTMLBlockKind? {
        guard indentWidth(line) < 4 else { return nil }
        let chars = Array(line.drop(while: { $0 == " " }))
        guard let first = chars.first, first == "<", chars.count > 1 else { return nil }
        let rest = String(chars.dropFirst())
        let lower = rest.lowercased()

        // Type 1: <script, <pre, <style, <textarea plus whitespace or >.
        for tag in ["script", "pre", "style", "textarea"] {
            guard lower.hasPrefix(tag) else { continue }
            let after = lower.index(lower.startIndex, offsetBy: tag.count)
            guard after < lower.endIndex else { continue }
            let c = lower[after]
            if c == " " || c == "\t" || c == "\u{0B}" || c == "\u{0C}" || c == "\r" || c == ">" {
                return .untilCloseTag
            }
        }
        if rest.hasPrefix("!--") { return .untilMarker("-->") }
        if rest.hasPrefix("?") { return .untilMarker("?>") }
        if rest.count >= 2, rest.hasPrefix("!"), rest[rest.index(rest.startIndex, offsetBy: 1)].isUppercase {
            return .untilMarker(">")
        }
        if rest.hasPrefix("![CDATA[") { return .untilMarker("]]>") }

        // Type 6: < or </ plus a block tag name plus whitespace, >, or />.
        var nameStart = rest.startIndex
        if rest[nameStart] == "/" { nameStart = rest.index(after: nameStart) }
        if nameStart < rest.endIndex, rest[nameStart].isLetter {
            var i = rest.index(after: nameStart)
            while i < rest.endIndex, rest[i].isLetter || rest[i].isNumber { i = rest.index(after: i) }
            if blockTagNames.contains(String(rest[nameStart..<i]).lowercased()) {
                guard i < rest.endIndex else { return nil }
                let c = rest[i]
                if c == " " || c == "\t" || c == "\u{0B}" || c == "\u{0C}" || c == "\r" || c == ">" {
                    return .untilBlank
                }
                if c == "/", rest.index(after: i) < rest.endIndex,
                   rest[rest.index(after: i)] == ">" {
                    return .untilBlank
                }
            }
        }

        // Type 7: one complete tag, nothing but whitespace after it.
        let tagLine = String(chars)
        if completeTagPattern.firstMatch(in: tagLine,
                                         range: NSRange(location: 0, length: (tagLine as NSString).length)) != nil {
            return .singleLine
        }
        return nil
    }

    private static func htmlBlockEnds(_ block: HTMLBlockKind, on line: String) -> Bool {
        switch block {
        case .singleLine: return true
        case .untilBlank: return line.trimmingCharacters(in: .whitespaces).isEmpty
        case .untilMarker(let marker): return line.contains(marker)
        case .untilCloseTag:
            let lower = line.lowercased()
            return lower.contains("</script>") || lower.contains("</pre>")
                || lower.contains("</style>") || lower.contains("</textarea>")
        }
    }

    private static func isBlockquote(_ line: String) -> Bool {
        guard indentWidth(line) < 4 else { return false }
        return line.drop(while: { $0 == " " }).first == ">"
    }

    /// A list marker: - * + or 1./1) followed by whitespace.
    private static func isListItem(_ line: String) -> Bool {
        guard indentWidth(line) < 4 else { return false }
        let chars = Array(line.drop(while: { $0 == " " }))
        guard !chars.isEmpty else { return false }
        if "-+*".contains(chars[0]) {
            return chars.count > 1 && (chars[1] == " " || chars[1] == "\t")
        }
        var digits = 0
        while digits < chars.count, chars[digits].isNumber { digits += 1 }
        guard digits > 0, digits < chars.count, digits <= 9 else { return false }
        return (chars[digits] == "." || chars[digits] == ")")
            && chars.count > digits + 1 && (chars[digits + 1] == " " || chars[digits + 1] == "\t")
    }

    private static let thematicBreakPattern = try! NSRegularExpression(
        pattern: "^ {0,3}((\\*\\s*){3,}|(-\\s*){3,}|(_\\s*){3,})$")

    private static func isThematicBreak(_ line: String) -> Bool {
        thematicBreakPattern.firstMatch(in: line,
                                        range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// A line that can be a table row: a bare pipe reads as zero cells in the
    /// GFM parser and closes the table instead.
    private static func isRowLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var pipes = 0
        for c in trimmed where c == "|" { pipes += 1 }
        return pipes >= 2 || trimmed.contains(where: { $0 != "|" })
    }

    /// A table body row: any line that can't open its own block (GFM's table-close rules).
    private static func isBodyRow(_ line: String) -> Bool {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard indentWidth(line) < 4 else { return false }
        guard isRowLine(line) else { return false }
        return fenceOpen(line) == nil
            && htmlBlockStart(line) == nil
            && atxHeading(line) == nil
            && !isBlockquote(line)
            && !isListItem(line)
            && !isThematicBreak(line)
    }

    /// A delimiter line's cell count and per-column alignment, or nil. A pure-hyphen
    /// line is a setext underline or thematic break, so a pipe or colon is required.
    private static func delimiterInfo(_ line: String) -> (cellCount: Int, alignments: [NSTextAlignment])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") || trimmed.contains(":") else { return nil }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [NSTextAlignment] = []
        for cell in cells {
            guard !cell.isEmpty, cell.contains("-"),
                  cell.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .right : .left)
        }
        return (cells.count, alignments)
    }

    /// The line's cells: one optional outer pipe stripped, then split on pipes that
    /// are neither backslash-escaped (odd run) nor inside a matched code span.
    private static func splitRow(_ line: String) -> [String] {
        var chars = Array(line.trimmingCharacters(in: .whitespaces))
        if let first = chars.first, first == "|" { chars.removeFirst() }
        if let last = chars.last, last == "|" { chars.removeLast() }
        let code = codeSpanIndices(chars)
        var cells: [[Character]] = [[]]
        for (i, c) in chars.enumerated() {
            if c == "|" && !code.contains(i) {
                var backslashes = 0
                var j = i - 1
                while j >= 0, chars[j] == "\\" { backslashes += 1; j -= 1 }
                if backslashes % 2 == 1 {
                    cells[cells.count - 1].removeLast()  // drop the escape backslash
                    cells[cells.count - 1].append("|")
                } else {
                    cells.append([])
                }
                continue
            }
            cells[cells.count - 1].append(c)
        }
        return cells.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Indices inside matched backtick code spans; an unmatched opener is
    /// literal text, so its backticks stay out of the set.
    private static func codeSpanIndices(_ chars: [Character]) -> Set<Int> {
        var inside: Set<Int> = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else { i += 1; continue }
            var run = 0
            while i + run < chars.count, chars[i + run] == "`" { run += 1 }
            var j = i + run
            var closed = false
            while j < chars.count {
                if chars[j] == "`" {
                    var run2 = 0
                    while j + run2 < chars.count, chars[j + run2] == "`" { run2 += 1 }
                    if run2 == run {
                        inside.formUnion(i..<j + run2)
                        i = j + run2
                        closed = true
                        break
                    }
                    j += run2
                } else {
                    j += 1
                }
            }
            if !closed { i += run }
        }
        return inside
    }

    /// Standard <table> HTML for the existing parser: head promotion, the delimiter's
    /// per-column alignment, and body rows padded to the header width (extras dropped).
    private static func buildHTML(header: String, delimiter: String, body: [String]) -> String {
        let headerCells = splitRow(header)
        let alignments = delimiterInfo(delimiter)?.alignments ?? []
        var lines: [String] = ["<table>", "<thead>", "<tr>"]
        for (i, cell) in headerCells.enumerated() {
            let align = i < alignments.count ? alignments[i] : .left
            lines.append("<th\(styleAttr(align))>\(convertInline(cell))</th>")
        }
        lines.append("</tr>")
        lines.append("</thead>")
        if !body.isEmpty {
            lines.append("<tbody>")
            for row in body {
                let cells = splitRow(row)
                lines.append("<tr>")
                for i in 0..<headerCells.count {
                    let align = i < alignments.count ? alignments[i] : .left
                    lines.append("<td\(styleAttr(align))>\(convertInline(i < cells.count ? cells[i] : ""))</td>")
                }
                lines.append("</tr>")
            }
            lines.append("</tbody>")
        }
        lines.append("</table>")
        return lines.joined(separator: "\n")
    }

    private static func styleAttr(_ alignment: NSTextAlignment) -> String {
        alignment == .left ? "" : " style=\"text-align: \(alignment.htmlName)\""
    }

    // MARK: - Inline conversion

    /// Cell text → HTML the fragment parser honors: <strong>, <em>, <a>, <br> only; code
    /// spans, images, and strikethrough degrade to text; non-representable tags strip keeping content.
    static func convertInline(_ text: String) -> String {
        parseInline(Array(text))
    }

    private static func parseInline(_ chars: [Character]) -> String {
        var out = ""
        var i = 0
        let n = chars.count

        while i < n {
            let c = chars[i]

            // A backslash escapes the next ASCII punctuation character.
            if c == "\\", i + 1 < n, isASCIIPunctuation(chars[i + 1]) {
                out += HTMLGenerator.escapeHTML(String(chars[i + 1]))
                i += 2
                continue
            }

            // Code span: literal content, markers stripped.
            if c == "`" {
                if let (content, end) = codeSpan(from: i, in: chars) {
                    out += HTMLGenerator.escapeHTML(content)
                    i = end
                } else {
                    var run = 0
                    while i + run < n, chars[i + run] == "`" { run += 1 }
                    out += HTMLGenerator.escapeHTML(String(chars[i..<(i + run)]))
                    i += run
                }
                continue
            }

            // Image: degraded to its alt text.
            if c == "!", i + 1 < n, chars[i + 1] == "[",
               let (alt, _, end) = linkParts(from: i + 1, in: chars) {
                out += HTMLGenerator.escapeHTML(alt)
                i = end
                continue
            }

            // Link: the label is parsed recursively.
            if c == "[", let (label, url, end) = linkParts(from: i, in: chars) {
                out += "<a href=\"\(HTMLGenerator.escapeAttribute(url))\">"
                out += parseInline(Array(label))
                out += "</a>"
                i = end
                continue
            }

            // Emphasis: *** bold+italic, ** bold, * italic (and the _ pairs).
            if c == "*" || c == "_", let (html, end) = emphasis(c, at: i, in: chars) {
                out += html
                i = end
                continue
            }

            // Strikethrough: degraded to its inner text.
            if c == "~", i + 1 < n, chars[i + 1] == "~",
               let (inner, end) = tildeDelimited(at: i, in: chars) {
                out += parseInline(inner)
                i = end
                continue
            }

            // Angle brackets: <br>, autolinks, representable tags (passed through), and
            // raw HTML (stripped). Attribute values may contain '>', so the scan tracks quotes.
            if c == "<" {
                var gt = i + 1
                var quote: Character?
                while gt < n {
                    let q = chars[gt]
                    if let open = quote {
                        if q == open { quote = nil }
                    } else if q == "\"" || q == "'" {
                        quote = q
                    } else if q == ">" {
                        break
                    }
                    gt += 1
                }
                if gt < n {
                    let inner = String(chars[(i + 1)..<gt])
                    if isBR(inner) {
                        out += "<br>"
                        i = gt + 1
                        continue
                    }
                    if let url = autolinkURL(inner) {
                        out += "<a href=\"\(HTMLGenerator.escapeAttribute(url))\">"
                        out += HTMLGenerator.escapeHTML(url)
                        out += "</a>"
                        i = gt + 1
                        continue
                    }
                    if isRepresentableTag(inner) {
                        out += "<\(inner)>"
                        i = gt + 1
                        continue
                    }
                    if isRawTag(inner) {
                        i = gt + 1
                        continue
                    }
                }
                out += HTMLGenerator.escapeHTML("<")
                i += 1
                continue
            }

            // A valid entity passes through verbatim; a bare ampersand is escaped so it survives as a literal.
            if c == "&", let (entity, end) = entity(from: i, in: chars) {
                out += entity
                i = end
                continue
            }

            out += HTMLGenerator.escapeHTML(String(c))
            i += 1
        }
        return out
    }

    /// A matched backtick code span's content (one leading/trailing space
    /// dropped when both are present) and the index past it, or nil.
    private static func codeSpan(from start: Int, in chars: [Character]) -> (String, Int)? {
        let n = chars.count
        var run = 0
        while start + run < n, chars[start + run] == "`" { run += 1 }
        var j = start + run
        while j < n {
            if chars[j] == "`" {
                var run2 = 0
                while j + run2 < n, chars[j + run2] == "`" { run2 += 1 }
                if run2 == run {
                    var content = String(chars[(start + run)..<j])
                    if content.hasPrefix(" "), content.hasSuffix(" "), content.count >= 2 {
                        content = String(content.dropFirst().dropLast())
                    }
                    return (content, j + run2)
                }
                j += run2
            } else {
                j += 1
            }
        }
        return nil
    }

    /// [label](destination "title") parts, or nil; the label may nest brackets, the
    /// destination may be angle-bracketed, and a title is dropped.
    private static func linkParts(from start: Int, in chars: [Character])
        -> (label: String, url: String, end: Int)? {
        let n = chars.count
        guard chars[start] == "[" else { return nil }
        var depth = 0
        var labelEnd = -1
        var j = start
        while j < n {
            if chars[j] == "\\", j + 1 < n { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" {
                depth -= 1
                if depth == 0 { labelEnd = j; break }
            }
            j += 1
        }
        guard labelEnd > start else { return nil }
        let label = String(chars[(start + 1)..<labelEnd])

        var k = labelEnd + 1
        while k < n, chars[k] == " " || chars[k] == "\t" { k += 1 }
        guard k < n, chars[k] == "(" else { return nil }
        k += 1
        while k < n, chars[k] == " " || chars[k] == "\t" { k += 1 }

        if k < n, chars[k] == "<" {
            var gt = k + 1
            while gt < n, chars[gt] != ">" { gt += 1 }
            guard gt < n else { return nil }
            let url = String(chars[(k + 1)..<gt])
            var m = gt + 1
            while m < n, chars[m] == " " || chars[m] == "\t" { m += 1 }
            guard m < n, chars[m] == ")" else { return nil }
            return (label, url, m + 1)
        }

        var paren = 0
        var m = k
        while m < n {
            if chars[m] == "\\", m + 1 < n { m += 2; continue }
            if chars[m] == "(" { paren += 1 }
            if chars[m] == ")" {
                if paren == 0 { break }
                paren -= 1
            }
            m += 1
        }
        guard m < n else { return nil }
        var destination = String(chars[k..<m])
        if let sp = destination.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            destination = String(destination[..<sp])
        }
        guard !destination.isEmpty else { return nil }
        return (label, destination, m + 1)
    }

    /// Emphasis at a * or _ run: *** bold+italic, ** bold, * italic (and the _ pairs);
    /// the closer is the next run of at least the same length, flanking-aware, skipping code spans.
    private static func emphasis(_ marker: Character, at start: Int, in chars: [Character])
        -> (String, Int)? {
        let n = chars.count
        var run = 0
        while start + run < n, chars[start + run] == marker { run += 1 }
        // A 4+ run re-matches from the next marker, leaving one literal on each side, exactly as GFM does.
        if run > 3 { return nil }
        let level = min(run, 3)
        // Flanking: the opener must not be followed by whitespace, and an
        // underscore can't open emphasis intraword.
        if start + run < n, isWhitespace(chars[start + run]) { return nil }
        if marker == "_", start > 0, isWordChar(chars[start - 1]) { return nil }

        var j = start + run
        while j < n {
            if chars[j] == "`" {
                if let (_, end) = codeSpan(from: j, in: chars) { j = end; continue }
                j += 1
                continue
            }
            if chars[j] == marker {
                var run2 = 0
                while j + run2 < n, chars[j + run2] == marker { run2 += 1 }
                let precededBySpace = j > start + run && isWhitespace(chars[j - 1])
                let followedByWord = marker == "_" && j + run2 < n && isWordChar(chars[j + run2])
                if run2 >= level, !precededBySpace, !followedByWord {
                    var html = parseInline(Array(chars[(start + run)..<j]))
                    if level >= 2 { html = "<strong>\(html)</strong>" }
                    if level == 1 || level == 3 { html = "<em>\(html)</em>" }
                    return (html, j + level)
                }
            }
            j += 1
        }
        return nil
    }

    /// A ~~...~~ span's inner characters and the index past it, or nil.
    private static func tildeDelimited(at start: Int, in chars: [Character]) -> ([Character], Int)? {
        let n = chars.count
        var j = start + 2
        while j < n {
            if chars[j] == "`" {
                if let (_, end) = codeSpan(from: j, in: chars) { j = end; continue }
                j += 1
                continue
            }
            if chars[j] == "~", j + 1 < n, chars[j + 1] == "~" {
                return (Array(chars[(start + 2)..<j]), j + 2)
            }
            j += 1
        }
        return nil
    }

    /// A valid entity at & (named or numeric), verbatim for the fragment
    /// parser to decode; nil means a bare ampersand to escape.
    private static func entity(from start: Int, in chars: [Character]) -> (String, Int)? {
        let n = chars.count
        let j = start + 1
        if j < n, chars[j] == "#" {
            var k = j + 1
            if k < n, chars[k] == "x" || chars[k] == "X" { k += 1 }
            let digitStart = k
            while k < n, chars[k].isHexDigit { k += 1 }
            guard k > digitStart, k < n, chars[k] == ";" else { return nil }
            return (String(chars[start..<k + 1]), k + 1)
        }
        var k = j
        while k < n, chars[k].isLetter { k += 1 }
        while k < n, chars[k].isNumber { k += 1 }
        guard k > j, k < n, chars[k] == ";" else { return nil }
        return (String(chars[start..<k + 1]), k + 1)
    }

    // The model's representable tags pass through; the rest are stripped.
    private static let representableTags: Set<String> = ["a", "b", "strong", "i", "em", "br"]

    private static func isBR(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t == "br" || t == "br/"
    }

    private static let autolinkPattern = try! NSRegularExpression(
        pattern: "^[a-zA-Z][a-zA-Z0-9+.-]*://\\S+$")

    private static func autolinkURL(_ s: String) -> String? {
        guard autolinkPattern.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        else { return nil }
        return s
    }

    /// The tag name of a raw HTML tag slice (between < and >), or nil; the
    /// name must be followed by whitespace, a closing slash, or the end.
    private static func rawTagName(_ s: String) -> String? {
        var rest = Substring(s)
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        guard let first = rest.first, first.isLetter else { return nil }
        var i = rest.index(after: rest.startIndex)
        while i < rest.endIndex, rest[i].isLetter || rest[i].isNumber { i = rest.index(after: i) }
        guard i == rest.endIndex
            || rest[i] == " " || rest[i] == "\t" || rest[i] == "/" else { return nil }
        return String(rest[..<i]).lowercased()
    }

    private static func isRepresentableTag(_ s: String) -> Bool {
        guard let name = rawTagName(s) else { return false }
        return representableTags.contains(name)
    }

    /// A raw HTML tag (name plus optional attributes); non-representable
    /// ones are stripped keeping their content.
    private static func isRawTag(_ s: String) -> Bool {
        rawTagName(s) != nil
    }

    private static func isASCIIPunctuation(_ c: Character) -> Bool {
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(c)
    }

    private static func isWhitespace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" || c == "\u{A0}"
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// A heading line's plain title: convert the inline markup, drop the tags, and decode the entities.
    private static func titleText(fromHeadingText text: String) -> String {
        var html = convertInline(text)
            .replacingOccurrences(of: "<br>", with: " ")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        html = HTMLParser.decodeEntities(html)
        return html.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Rendering

    /// The table as GFM pipe-table Markdown, or nil without a header row (Markdown requires
    /// one). Merged cells flatten to their top-left slot; the delimiter carries the head's alignment.
    @MainActor
    static func markdown(for table: Table) -> String? {
        guard let headIndex = table.rows.firstIndex(where: { $0.section == .head }) else { return nil }
        let cols = max(table.columnCount, 1)
        let slots = table.placements()

        var grid: [[String]] = []
        for row in table.rows.indices {
            var line = Array(repeating: "", count: cols)
            for p in slots[row] where p.startCol < cols {
                line[p.startCol] = renderCell(table.rows[row].cells[p.cellIndex])
            }
            grid.append(line)
        }

        var alignments = Array(repeating: NSTextAlignment.left, count: cols)
        for p in slots[headIndex] where p.startCol < cols {
            let align = table.rows[headIndex].cells[p.cellIndex].alignment
            for c in p.startCol..<min(p.startCol + p.colSpan, cols) { alignments[c] = align }
        }

        var lines = [formatRow(grid[headIndex]), formatRow(alignments.map(delimiterCell))]
        for row in table.rows.indices where row != headIndex {
            lines.append(formatRow(grid[row]))
        }
        return lines.joined(separator: "\n")
    }

    private static func formatRow(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }

    private static func delimiterCell(_ alignment: NSTextAlignment) -> String {
        switch alignment {
        case .center: return ":---:"
        case .right: return "---:"
        default: return "---"
        }
    }

    /// One cell's attributed content as Markdown: the model's bold, italic, link, and
    /// newline become ** * []() and <br>; plain text is escaped so a re-import parses identically.
    private static func renderCell(_ cell: TableCell) -> String {
        let text = cell.content
        guard text.length > 0 else { return "" }
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            var fragment = escapeMarkdownText(String(text.attributedSubstring(from: range).string))
            fragment = fragment.replacingOccurrences(of: "\n", with: "<br>")
            var bold = false
            var italic = false
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                bold = traits.contains(.boldFontMask)
                italic = traits.contains(.italicFontMask)
            }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? "\(link)"
                let dest = url.contains("(") || url.contains(")") || url.contains(" ")
                    ? "<\(url)>" : url
                fragment = "[\(fragment)](\(dest))"
            }
            if bold, italic { fragment = "***\(fragment)***" }
            else if bold { fragment = "**\(fragment)**" }
            else if italic { fragment = "*\(fragment)*" }
            result += fragment
        }
        return result
    }

    /// Escapes what Markdown would read as syntax, so a rendered cell re-imports byte-identical.
    private static func escapeMarkdownText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "\\": out += "\\\\"
            case "&": out += "&amp;"
            case "|": out += "\\|"
            case "*": out += "\\*"
            case "_": out += "\\_"
            case "[": out += "\\["
            case "]": out += "\\]"
            case "<": out += "\\<"
            case ">": out += "\\>"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: - Loss disclosure

    /// The specific markup Markdown cannot keep, one line per condition; empty when the table exports cleanly.
    static func losses(for table: Table) -> [String] {
        var losses: [String] = []
        let slots = table.placements()
        let cols = max(table.columnCount, 1)
        let headIndex = table.rows.firstIndex { $0.section == .head }

        let merged = table.rows.flatMap { row in row.cells.filter { $0.colspan > 1 || $0.rowspan > 1 } }
        if !merged.isEmpty {
            losses.append("\(merged.count) merged cell\(merged.count == 1 ? "" : "s") will be flattened to their top-left slot.")
        }

        if table.caption != nil || table.captionRaw != nil {
            losses.append("The caption will be dropped.")
        }

        if !table.attributes.isEmpty {
            var seen: [String] = []
            for attribute in table.attributes where !seen.contains(attribute.name) {
                seen.append(attribute.name)
            }
            losses.append("Table attributes (\(seen.joined(separator: ", "))) will be dropped.")
        }

        if !table.columnMarkup.isEmpty {
            losses.append("Column markup will be dropped.")
        }

        if !table.sourcePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !table.sourceSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            losses.append("Markup outside the table will be dropped.")
        }

        var attrNames: [String] = []
        var attrCellCount = 0
        for row in table.rows {
            for cell in row.cells where !cell.rawAttributes.isEmpty {
                attrCellCount += 1
                for name in names(matching: attributeNamePattern, in: cell.rawAttributes)
                    where !attrNames.contains(name) {
                    attrNames.append(name)
                }
            }
        }
        if attrCellCount > 0 {
            losses.append("Cell attributes (\(attrNames.joined(separator: ", "))) on \(attrCellCount) cell\(attrCellCount == 1 ? "" : "s") will be dropped.")
        }

        // The delimiter carries one alignment per column; mixed cells lose.
        if let headIndex {
            for col in 0..<cols {
                var seen: [String] = []
                for row in table.rows.indices {
                    for p in slots[row] where p.startCol <= col && col < p.startCol + p.colSpan {
                        let name = table.rows[row].cells[p.cellIndex].alignment.menuTitle.lowercased()
                        if !seen.contains(name) { seen.append(name) }
                    }
                }
                if seen.count > 1 {
                    var head = "left"
                    for p in slots[headIndex] where p.startCol <= col && col < p.startCol + p.colSpan {
                        head = table.rows[headIndex].cells[p.cellIndex].alignment.menuTitle.lowercased()
                    }
                    losses.append("Column \(col + 1) has mixed alignment (\(seen.joined(separator: ", "))); it will export as \(head).")
                }
            }
        }

        let headRows = table.rows.filter { $0.section == .head }
        if headRows.count > 1 {
            losses.append("\(headRows.count - 1) extra header row\(headRows.count - 1 == 1 ? "" : "s") will become body rows.")
        }

        let footRows = table.rows.filter { $0.section == .foot }
        if !footRows.isEmpty {
            losses.append("\(footRows.count) footer row\(footRows.count == 1 ? "" : "s") will become body rows.")
        }

        // Non-representable HTML: tags outside the model's bold/italic/link/newline set.
        var tags: [String] = []
        var htmlCellCount = 0
        for row in table.rows {
            for cell in row.cells {
                guard let raw = cell.rawInnerHTML else { continue }
                let found = names(matching: tagNamePattern, in: raw)
                    .filter { !representableTags.contains($0) }
                if !found.isEmpty {
                    htmlCellCount += 1
                    for tag in found where !tags.contains(tag) { tags.append(tag) }
                }
            }
        }
        if htmlCellCount > 0 {
            losses.append("\(htmlCellCount) cell\(htmlCellCount == 1 ? "" : "s") contain HTML (\(tags.map { "<" + $0 + ">" }.joined(separator: ", "))) that Markdown cannot represent.")
        }

        return losses
    }

    private static let attributeNamePattern = try! NSRegularExpression(
        pattern: "\\b([a-zA-Z][a-zA-Z0-9-]*)\\s*=")
    private static let tagNamePattern = try! NSRegularExpression(
        pattern: "</?([a-zA-Z][a-zA-Z0-9]*)")

    private static func names(matching pattern: NSRegularExpression, in text: String) -> [String] {
        var seen: [String] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r]).lowercased()
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }
}

// File picking behind protocols so tests script the chosen URL instead of raising
// a panel, mirroring the CSV seams. Both present as a titlebar-anchored sheet.

protocol MarkdownFileImporting {
    func chooseMarkdownFile(prompt: String, into window: NSWindow?, completion: @escaping (URL?) -> Void)
}

protocol MarkdownFileExporting {
    func chooseMarkdownFile(prompt: String, suggestedName: String, defaultURL: URL?,
                            into window: NSWindow?, completion: @escaping (URL?) -> Void)
}

private let markdownImportTypes: [UTType] = {
    var types: [UTType] = []
    if let md = UTType(filenameExtension: "md") { types.append(md) }
    if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
    types.append(.plainText)
    return types
}()

struct SystemMarkdownImporter: MarkdownFileImporting {
    func chooseMarkdownFile(prompt: String, into window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.allowedContentTypes = markdownImportTypes
        panel.delegate = ImportPanelFilter.markdown
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

struct SystemMarkdownExporter: MarkdownFileExporting {
    func chooseMarkdownFile(prompt: String, suggestedName: String, defaultURL: URL?,
                            into window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.prompt = prompt
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = defaultURL
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}
