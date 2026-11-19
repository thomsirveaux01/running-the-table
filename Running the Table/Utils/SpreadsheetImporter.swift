import AppKit
import UniformTypeIdentifiers

/// One sheet of an imported workbook: its source name plus the table it became.
struct ImportedSpreadsheetSheet {
    var name: String
    var table: Table
}

enum SpreadsheetImportError: LocalizedError {
    case notAnArchive
    case missingParts

    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "The file could not be read as a spreadsheet archive."
        case .missingParts: return "The file is missing the parts a spreadsheet needs."
        }
    }
}

/// .xlsx and .ods readers: both are zip packages of XML, read via ZipReader
/// (libarchive) and Foundation's SAX parser. Values import raw; only bold/italic styling carries over.
enum SpreadsheetImporter {
    /// Every sheet of one .xlsx or .ods file, in workbook order.
    static func sheets(in url: URL) throws -> [ImportedSpreadsheetSheet] {
        switch url.pathExtension.lowercased() {
        case "xlsx": return try xlsxSheets(in: url)
        case "ods": return try odsSheets(in: url)
        default: throw SpreadsheetImportError.missingParts
        }
    }

    // MARK: - Zip

    private static func entry(_ url: URL, _ path: String) throws -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var size: Int64 = 0
        guard zipreader_read_entry(url.path, path, &pointer, &size) == ZIPREADER_OK, let pointer else {
            throw SpreadsheetImportError.notAnArchive
        }
        defer { zipreader_free(pointer) }
        return Data(bytes: pointer, count: Int(size))
    }

    // MARK: - Shared grid model

    /// How the source format typed the cell; drives formula evaluation and
    /// number display.
    enum RawKind {
        case number
        case text
        case boolean
        case error
    }

    /// One parsed cell before table construction; row/col are 0-based.
    struct RawCell {
        var row: Int
        var col: Int
        var text = ""
        var kind: RawKind = .text
        /// xlsx only: the cell's formula, evaluated when the cache is empty.
        var formula: String?
        var styleIndex: Int?
        /// ODS only: the cell's style name, resolved to a styleIndex by the caller.
        var styleName: String?
        /// Display-only override of `text` (dates); the evaluator keeps `text`.
        var display: String?
    }

    private struct RawMerge {
        var row: Int
        var col: Int
        var colspan: Int
        var rowspan: Int
    }

    /// Builds the model's merge-aware grid: covered slots are not materialized,
    /// and the trailing empty rows/columns the formats pad out are trimmed.
    private static func makeTable(named name: String, cells: [RawCell], merges: [RawMerge],
                                  styles: [(bold: Bool, italic: Bool)]) -> Table {
        guard !cells.isEmpty else { return Table(rows: [[TableCell()]], name: name) }
        var values: [Int: [Int: String]] = [:]
        var styleOf: [Int: [Int: Int]] = [:]
        var rowHasContent = Set<Int>()
        var colHasContent = Set<Int>()
        for c in cells {
            let text = c.display ?? c.text
            values[c.row, default: [:]][c.col] = text
            if let styleIndex = c.styleIndex { styleOf[c.row, default: [:]][c.col] = styleIndex }
            // Only real content anchors the extent; the formats pad grids with
            // empty cells that the trim below must drop.
            if !text.isEmpty {
                rowHasContent.insert(c.row)
                colHasContent.insert(c.col)
            }
        }
        var topLeft: [Int: [Int: (colspan: Int, rowspan: Int)]] = [:]
        // Grid slots as flat keys; tuples are not Hashable.
        var covered: Set<Int> = []
        func slot(_ row: Int, _ col: Int) -> Int { row * 100_000 + col }
        for m in merges {
            guard m.row >= 0, m.col >= 0, m.colspan > 0, m.rowspan > 0 else { continue }
            topLeft[m.row, default: [:]][m.col] = (m.colspan, m.rowspan)
            for dr in 0..<m.rowspan {
                rowHasContent.insert(m.row + dr)
                for dc in 0..<m.colspan {
                    colHasContent.insert(m.col + dc)
                    if dr != 0 || dc != 0 { covered.insert(slot(m.row + dr, m.col + dc)) }
                }
            }
        }
        // A merge can reach past the last cell (a fully covered trailing row).
        let mergeRowEnd = merges.map { $0.row + $0.rowspan - 1 }.max() ?? 0
        let mergeColEnd = merges.map { $0.col + $0.colspan - 1 }.max() ?? 0
        var extentRow = max(cells.map(\.row).max() ?? 0, mergeRowEnd)
        while extentRow >= 0, !rowHasContent.contains(extentRow) { extentRow -= 1 }
        var extentCol = max(cells.map(\.col).max() ?? 0, mergeColEnd)
        while extentCol >= 0, !colHasContent.contains(extentCol) { extentCol -= 1 }
        guard extentRow >= 0, extentCol >= 0 else { return Table(rows: [[TableCell()]], name: name) }

        var rows: [TableRow] = []
        for r in 0...extentRow {
            var rowCells: [TableCell] = []
            for c in 0...extentCol {
                if covered.contains(slot(r, c)) { continue }
                let text = values[r]?[c] ?? ""
                var cell = TableCell(content: HTMLParser.plainAttributed(text))
                if let s = styleOf[r]?[c], styles.indices.contains(s),
                   styles[s].bold || styles[s].italic {
                    cell.content = NSAttributedString(string: text,
                                                      attributes: HTMLParser.cellAttributes(bold: styles[s].bold,
                                                                                            italic: styles[s].italic,
                                                                                            link: nil))
                }
                if let span = topLeft[r]?[c] {
                    cell.colspan = span.colspan
                    cell.rowspan = span.rowspan
                }
                rowCells.append(cell)
            }
            rows.append(TableRow(cells: rowCells))
        }
        var table = Table(rows: rows, name: name)
        table.normalize()
        return table
    }

    // MARK: - xlsx

    private static func xlsxSheets(in url: URL) throws -> [ImportedSpreadsheetSheet] {
        let sheets = parseWorkbookSheets(try entry(url, "xl/workbook.xml"))
        guard !sheets.isEmpty else { throw SpreadsheetImportError.missingParts }
        let targets = parseRelationshipTargets(try? entry(url, "xl/_rels/workbook.xml.rels"))
        let shared = parseSharedStrings(try? entry(url, "xl/sharedStrings.xml"))
        let styles = parseXLSXCellStyles(try? entry(url, "xl/styles.xml"))

        var parsed: [(name: String, cells: [RawCell], merges: [RawMerge])] = []
        for (name, rId) in sheets {
            guard let target = targets[rId] else { continue }
            // Targets are relative to xl/; a leading slash is package-absolute.
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let xml = try? entry(url, path) else { continue }
            let (cells, merges) = parseXLSXWorksheet(xml, shared: shared, dateFormats: styles.map(\.dateFormat))
            parsed.append((name, cells, merges))
        }
        guard !parsed.isEmpty else { throw SpreadsheetImportError.missingParts }

        // Tools like Openpyxl store formulas without computed results; evaluate
        // those once so the import carries values, not blanks.
        let filled = FormulaEvaluator.fillMissingValues(in: parsed.map { (name: $0.name, cells: $0.cells) },
                                                        dateFormats: styles.map(\.dateFormat))
        return zip(filled, parsed).map { filled, source in
            ImportedSpreadsheetSheet(name: filled.name,
                                     table: makeTable(named: filled.name, cells: filled.cells, merges: source.merges,
                                                      styles: styles.map { ($0.bold, $0.italic) }))
        }
    }

    /// Sheet names in workbook order, each with the relationship id of its worksheet part.
    private static func parseWorkbookSheets(_ data: Data) -> [(name: String, rId: String)] {
        final class Handler: NSObject, XMLParserDelegate {
            var sheets: [(String, String)] = []
            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                guard element == "sheet", let sheetName = attributes["name"] else { return }
                sheets.append((sheetName, attributes["r:id"] ?? ""))
            }
        }
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.sheets
    }

    private static func parseRelationshipTargets(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        final class Handler: NSObject, XMLParserDelegate {
            var targets: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                guard element == "Relationship", let id = attributes["Id"],
                      let target = attributes["Target"] else { return }
                targets[id] = target
            }
        }
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.targets
    }

    /// Shared string table; a string may hold several rich-text <t> runs.
    private static func parseSharedStrings(_ data: Data?) -> [String] {
        guard let data else { return [] }
        final class Handler: NSObject, XMLParserDelegate {
            var strings: [String] = []
            private var current = ""
            private var inText = false
            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                if element == "si" { current = "" }
                if element == "t" { inText = true }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inText { current += string }
            }
            func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
                if element == "t" { inText = false }
                if element == "si" { strings.append(current) }
            }
        }
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.strings
    }

    /// Per cellXfs slot: the font's bold/italic and, when the slot's number
    /// format is a date, the Foundation format that renders it; a cell's s
    /// attribute indexes this.
    private static func parseXLSXCellStyles(_ data: Data?) -> [(bold: Bool, italic: Bool, dateFormat: String?)] {
        guard let data else { return [] }
        final class Handler: NSObject, XMLParserDelegate {
            var fonts: [(Bool, Bool)] = []
            var numFmts: [Int: String] = [:]
            var xfFontIds: [Int] = []
            var xfNumFmtIds: [Int] = []
            private var inFonts = false
            private var inNumFmts = false
            private var inXfs = false
            private var bold = false
            private var italic = false
            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch element {
                case "fonts": inFonts = true
                case "numFmts": inNumFmts = true
                case "cellXfs": inXfs = true
                case "numFmt" where inNumFmts:
                    if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] {
                        numFmts[id] = code
                    }
                case "font" where inFonts: bold = false; italic = false
                // val="0"/"false" is an explicit off; a bare <b/> is on.
                case "b" where inFonts: bold = !(attributes["val"] == "0" || attributes["val"] == "false")
                case "i" where inFonts: italic = !(attributes["val"] == "0" || attributes["val"] == "false")
                case "xf" where inXfs:
                    if let id = attributes["fontId"].flatMap(Int.init) { xfFontIds.append(id) }
                    xfNumFmtIds.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
                switch element {
                case "font" where inFonts: fonts.append((bold, italic))
                case "fonts": inFonts = false
                case "numFmts": inNumFmts = false
                case "cellXfs": inXfs = false
                default: break
                }
            }
        }
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.xfFontIds.enumerated().map { i, fontId in
            let font = handler.fonts.indices.contains(fontId) ? handler.fonts[fontId] : (false, false)
            // Built-in date ids carry no formatCode; custom ones live in numFmts.
            let code = Self.builtinDateFormats[handler.xfNumFmtIds[i]] ?? handler.numFmts[handler.xfNumFmtIds[i]]
            return (bold: font.0, italic: font.1, dateFormat: code.flatMap(Self.foundationDateFormat(from:)))
        }
    }

    /// Built-in numFmtIds that display dates, with their en-US codes (27–36 and
    /// 50–58 are locale-dependent; these are the US forms).
    private static let builtinDateFormats: [Int: String] = [
        14: "m/d/yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy",
        18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss",
        22: "m/d/yy h:mm",
        27: "mm-dd-yy", 28: "d-mmm-yy", 29: "d-mmm", 30: "mmm-yy",
        31: "h:mm:ss", 32: "h:mm", 33: "h:mm:ss", 34: "m/d/yy h:mm",
        35: "m-d-yy h:mm", 36: "mm/dd/yy h:mm",
        45: "h:mm:ss.000", 46: "@h:mm:ss", 47: "h:mm:ss.0",
        50: "m/d/yy", 51: "d-mmm-yy", 52: "d-mmm", 53: "mmm-yy",
        54: "m/d/yy h:mm", 55: "mm-dd-yy h:mm", 56: "m-d-yy h:mm",
        57: "mm/dd/yy h:mm", 58: "m/d/yy h:mm",
    ]

    /// Excel format code → Foundation date format, or nil when the code has no
    /// date or time tokens at all (i.e. it isn't a date format).
    nonisolated static func foundationDateFormat(from excelCode: String) -> String? {
        // First pass: split the code into literal chunks and token runs.
        struct Run {
            let ch: Character
            let count: Int
            let literal: String
        }
        var runs: [Run] = []
        let chars = Array(excelCode)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                // Quoted literal: copy verbatim, quotes included.
                i += 1
                var lit = "\""
                while i < chars.count {
                    lit.append(chars[i])
                    if chars[i] == "\"" { i += 1; break }
                    i += 1
                }
                runs.append(Run(ch: " ", count: 0, literal: lit))
                continue
            }
            if c == "\\" {
                // Escaped literal character.
                i += 1
                var lit = ""
                if i < chars.count {
                    let l = chars[i]
                    lit = l.isLetter ? "'\(l)'" : String(l)
                    i += 1
                }
                runs.append(Run(ch: " ", count: 0, literal: lit))
                continue
            }
            // AM/PM (and case/short variants) is one Foundation token.
            if "AaPp".contains(c) {
                let rest = String(chars[i...])
                var matched = false
                for pattern in ["AM/PM", "am/pm", "A/P", "a/p"] where rest.hasPrefix(pattern) {
                    runs.append(Run(ch: "a", count: 1, literal: ""))
                    i += pattern.count
                    matched = true
                    break
                }
                if matched { continue }
            }
            var run = 1
            while i + run < chars.count, chars[i + run] == c { run += 1 }
            if "ymdHhs".contains(c) {
                runs.append(Run(ch: c, count: run, literal: ""))
            } else if c == "0" || c == "#" {
                // Fractional seconds in a time context; literal otherwise.
                runs.append(Run(ch: "f", count: run, literal: ""))
            } else if c == "?" || c == "@" {
                // Padding placeholder / time-only marker: drop.
                runs.append(Run(ch: " ", count: 0, literal: ""))
            } else {
                runs.append(Run(ch: " ", count: 0, literal: c.isLetter ? "'\(c)'" : String(c)))
            }
            i += run
        }
        // Second pass: map tokens; an m run is minutes only when a time token
        // (h/H/s) sits next to it, otherwise months.
        var out = ""
        var sawToken = false
        for (idx, run) in runs.enumerated() {
            out += run.literal
            guard run.count > 0 else { continue }
            // Fraction runs alone don't make a date ("0.00" is a number).
            if "ymdHhsa".contains(run.ch) { sawToken = true }
            func neighbor(_ dir: Int) -> Character? {
                var j = idx + dir
                while j >= 0, j < runs.count {
                    if runs[j].count > 0 { return runs[j].ch }
                    j += dir
                }
                return nil
            }
            let isMinute = "hHs".contains(neighbor(-1) ?? " ") || "hHs".contains(neighbor(1) ?? " ")
            let hasTimeToken = runs.contains { $0.count > 0 && "hHs".contains($0.ch) }
            switch run.ch {
            case "y": out += String(repeating: "y", count: min(run.count, 4))
            case "d": out += run.count >= 4 ? "EEEE" : run.count == 3 ? "EEE" : String(repeating: "d", count: run.count)
            case "m":
                out += isMinute ? String(repeating: "m", count: min(run.count, 2))
                    : (run.count >= 5 ? "MMM" : run.count == 4 ? "MMMM" : run.count == 3 ? "MMM" : String(repeating: "M", count: run.count))
            case "h": out += String(repeating: "h", count: min(run.count, 2))
            case "H": out += String(repeating: "H", count: min(run.count, 2))
            case "s": out += run.count == 3 ? "SSS" : String(repeating: "s", count: min(run.count, 2))
            case "a": out += "a"
            case "f":
                out += hasTimeToken ? String(repeating: "S", count: min(run.count, 3))
                    : String(repeating: "0", count: run.count)
            default: break
            }
        }
        return sawToken ? out : nil
    }

    /// Excel's 1900-system serial (days since 1899-12-30, around the phantom
    /// 1900-02-29) as a wall-clock Date in the local calendar.
    nonisolated static func date(fromSerial serial: Double) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        guard let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30)) else {
            return .distantPast
        }
        let days = Int(serial.rounded(.down))
        let fraction = serial - Double(days)
        var dayOffset = days
        if serial > 0, serial < 60 { dayOffset += 1 }
        guard var date = calendar.date(byAdding: .day, value: dayOffset, to: base) else {
            return .distantPast
        }
        let seconds = Int((fraction * 86_400).rounded())
        date = calendar.date(byAdding: .second, value: seconds, to: date) ?? date
        return date
    }

    /// A serial rendered with a Foundation date format, localized like Excel.
    nonisolated static func dateDisplay(serial: Double, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = format
        return formatter.string(from: date(fromSerial: serial))
    }

    /// ODS stores dates as ISO 8601 ("2026-01-01", "2026-01-01T14:30:00") and
    /// times bare ("14:30:00"); render each as a readable local value.
    nonisolated static func odsDateDisplay(_ raw: String) -> String {
        let hasDate = raw.contains("-")
        let patterns = hasDate
            ? ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"]
            : ["HH:mm:ss", "HH:mm"]
        for pattern in patterns {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = pattern
            guard let date = parser.date(from: raw) else { continue }
            let out = DateFormatter()
            out.locale = .current
            out.dateFormat = hasDate ? (raw.contains("T") ? "M/d/yyyy, h:mm a" : "M/d/yyyy") : "h:mm a"
            return out.string(from: date)
        }
        return raw
    }

    /// ODS durations are whole seconds in office:value; render as h:mm:ss.
    nonisolated static func durationDisplay(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func parseXLSXWorksheet(_ data: Data, shared: [String], dateFormats: [String?])
        -> (cells: [RawCell], merges: [RawMerge]) {
        final class Handler: NSObject, XMLParserDelegate {
            var cells: [RawCell] = []
            var merges: [RawMerge] = []
            // Set after init: a nested class cannot close over the function's parameter.
            var shared: [String] = []
            var dateFormats: [String?] = []
            private var rowNumber = 0
            private var lastRow = 0
            private var cellRef = ""
            private var cellType = ""
            private var styleIndex: Int?
            private var valueText = ""
            private var formulaText = ""
            private var inValue = false
            private var inFormula = false
            private var inText = false

            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch element {
                case "row":
                    rowNumber = attributes["r"].flatMap(Int.init) ?? lastRow + 1
                    lastRow = rowNumber
                case "c":
                    cellRef = attributes["r"] ?? ""
                    cellType = attributes["t"] ?? ""
                    styleIndex = attributes["s"].flatMap(Int.init)
                    valueText = ""
                    formulaText = ""
                case "f": inFormula = true
                case "v": inValue = true
                case "t" where cellType == "inlineStr": inText = true
                case "mergeCell":
                    if let ref = attributes["ref"], let m = SpreadsheetImporter.parseMergeRef(ref) {
                        merges.append(RawMerge(row: m.row, col: m.col, colspan: m.colspan, rowspan: m.rowspan))
                    }
                default: break
                }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inValue || inText { valueText += string }
                else if inFormula { formulaText += string }
            }
            func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
                switch element {
                case "f": inFormula = false
                case "v": inValue = false
                case "t": inText = false
                case "c":
                    let kind: RawKind
                    switch cellType {
                    case "", "n": kind = .number
                    case "b": kind = .boolean
                    case "e": kind = .error
                    default: kind = .text
                    }
                    var text = valueText
                    if cellType == "s", let index = Int(valueText), shared.indices.contains(index) {
                        text = shared[index]
                    } else if kind == .number {
                        text = valueText.isEmpty ? "" : SpreadsheetImporter.numericDisplay(Double(valueText) ?? 0)
                    } else if kind == .boolean {
                        text = valueText.isEmpty ? "" : (valueText == "1" || valueText.uppercased() == "TRUE" ? "TRUE" : "FALSE")
                    }
                    // A date-styled number displays as a date; the serial stays
                    // in text so formulas referencing the cell keep working.
                    var display: String?
                    if kind == .number, let serial = Double(valueText),
                       let style = styleIndex, dateFormats.indices.contains(style),
                       let format = dateFormats[style] {
                        display = SpreadsheetImporter.dateDisplay(serial: serial, format: format)
                    }
                    // An empty <f> body is a shared-formula follower, which we
                    // can't translate; treat it as a plain (empty) cell.
                    cells.append(RawCell(row: rowNumber - 1, col: SpreadsheetImporter.xlsxColumnIndex(cellRef),
                                         text: text, kind: kind,
                                         formula: formulaText.isEmpty ? nil : formulaText,
                                         styleIndex: styleIndex, display: display))
                default: break
                }
            }
        }
        let handler = Handler()
        handler.shared = shared
        handler.dateFormats = dateFormats
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return (handler.cells, handler.merges)
    }

    /// Excel's General format shows at most 11 significant digits; match it so
    /// imports read as the source app displayed them (also drops float artifacts).
    nonisolated static func numericDisplay(_ d: Double) -> String {
        guard d == d.rounded(), abs(d) < 1e15 else { return String(format: "%.11g", d) }
        return Int64(d).description
    }

    /// The 0-based column of a cell reference like "BC12".
    private static func xlsxColumnIndex(_ ref: String) -> Int {
        var col = 0
        for scalar in ref.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            col = col * 26 + Int(scalar.value - 64)
        }
        return max(col - 1, 0)
    }

    /// "A1:B2" → top-left plus span, 0-based.
    private static func parseMergeRef(_ ref: String) -> (row: Int, col: Int, colspan: Int, rowspan: Int)? {
        let ends = ref.split(separator: ":").map(String.init)
        guard ends.count == 2, let a = decomposeRef(ends[0]), let b = decomposeRef(ends[1]),
              b.row >= a.row, b.col >= a.col else { return nil }
        return (a.row, a.col, b.col - a.col + 1, b.row - a.row + 1)
    }

    private static func decomposeRef(_ ref: String) -> (row: Int, col: Int)? {
        var col = 0
        var rowText = ""
        for scalar in ref.unicodeScalars {
            if scalar.value >= 65, scalar.value <= 90 {
                col = col * 26 + Int(scalar.value - 64)
            } else {
                rowText.append(Character(scalar))
            }
        }
        guard col > 0, let row = Int(rowText), row > 0 else { return nil }
        return (row - 1, col - 1)
    }

    // MARK: - ods

    /// ODS pads rows and cells with repeat counts (often 1024+); materialize at
    /// most this many copies, then the trailing-empty trim drops the padding.
    private static let maxRepeat = 1024

    private static func odsSheets(in url: URL) throws -> [ImportedSpreadsheetSheet] {
        guard let content = try? entry(url, "content.xml") else { throw SpreadsheetImportError.missingParts }
        let (sheets, automatic) = parseODSContent(content)
        var named = parseODSStyles(try? entry(url, "styles.xml"))
        named.merge(automatic) { _, new in new }
        guard !sheets.isEmpty else { throw SpreadsheetImportError.missingParts }

        // Cell style names resolve against both style tables; distinct names
        // become slots in the shared styles array makeTable indexes into.
        var styles: [(bold: Bool, italic: Bool)] = []
        var index: [String: Int] = [:]
        var resolved: [(name: String, cells: [RawCell], merges: [RawMerge])] = []
        for sheet in sheets {
            var cells = sheet.cells
            for i in cells.indices where cells[i].styleName != nil {
                let name = cells[i].styleName!
                if index[name] == nil {
                    index[name] = styles.count
                    styles.append(named[name] ?? (false, false))
                }
                cells[i].styleIndex = index[name]
            }
            resolved.append((sheet.name, cells, sheet.merges))
        }
        return resolved.map {
            ImportedSpreadsheetSheet(name: $0.name,
                                     table: makeTable(named: $0.name, cells: $0.cells, merges: $0.merges, styles: styles))
        }
    }

    /// Named table-cell styles from styles.xml; ODF element names carry their
    /// namespace prefix ("style:style"), so the cases match the qualified names.
    private static func parseODSStyles(_ data: Data?) -> [String: (bold: Bool, italic: Bool)] {
        guard let data else { return [:] }
        final class Handler: NSObject, XMLParserDelegate {
            var styles: [String: (bold: Bool, italic: Bool)] = [:]
            private var inStyles = false
            private var currentName: String?
            private var bold = false
            private var italic = false
            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch element {
                // The root, not the inner <styles> section, scopes the scan.
                case "office:styles": inStyles = true
                case "style:style" where inStyles:
                    if attributes["style:family"] == "table-cell" {
                        currentName = attributes["style:name"]
                        bold = false
                        italic = false
                    }
                case "style:text-properties" where inStyles:
                    if attributes["fo:font-weight"] == "bold" { bold = true }
                    if attributes["fo:font-style"] == "italic" { italic = true }
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
                switch element {
                case "style:style" where inStyles:
                    if let currentName { styles[currentName] = (bold, italic) }
                    currentName = nil
                case "office:styles": inStyles = false
                default: break
                }
            }
        }
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.styles
    }

    /// Sheets in document order, plus the automatic cell styles content.xml defines.
    private static func parseODSContent(_ data: Data)
        -> (sheets: [(name: String, cells: [RawCell], merges: [RawMerge])],
            styles: [String: (bold: Bool, italic: Bool)]) {
        final class Handler: NSObject, XMLParserDelegate {
            struct Sheet {
                var name: String
                var cells: [RawCell] = []
                var merges: [RawMerge] = []
            }
            var sheets: [Sheet] = []
            var styles: [String: (bold: Bool, italic: Bool)] = [:]

            private var inAutomaticStyles = false
            private var autoName: String?
            private var autoBold = false
            private var autoItalic = false

            private var sheet: Sheet?
            private var rowNumber = 0
            private var column = 0
            private var rowRepeat = 1
            private var rowCellStart = 0
            private var rowMergeStart = 0
            private var inCell = false
            private var cellStyle: String?
            private var cellValueType = ""
            private var cellValue = ""
            private var cellText = ""
            private var cellRepeat = 1
            private var spannedCols = 1
            private var spannedRows = 1

            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch element {
                case "office:automatic-styles": inAutomaticStyles = true
                case "style:style" where inAutomaticStyles:
                    if attributes["style:family"] == "table-cell" {
                        autoName = attributes["style:name"]
                        autoBold = false
                        autoItalic = false
                    }
                case "style:text-properties" where inAutomaticStyles:
                    if attributes["fo:font-weight"] == "bold" { autoBold = true }
                    if attributes["fo:font-style"] == "italic" { autoItalic = true }
                case "table:table":
                    sheet = Sheet(name: attributes["table:name"] ?? "Sheet")
                    // Row and column counters are per-sheet.
                    rowNumber = 0
                    column = 0
                case "table:table-row" where sheet != nil:
                    column = 0
                    rowRepeat = attributes["table:number-rows-repeated"].flatMap(Int.init) ?? 1
                    rowCellStart = sheet!.cells.count
                    rowMergeStart = sheet!.merges.count
                case "table:table-cell" where sheet != nil:
                    inCell = true
                    cellStyle = attributes["table:style:name"]
                    cellValueType = attributes["office:value-type"] ?? ""
                    cellValue = attributes["office:value"]
                        ?? attributes["office:date-value"]
                        ?? attributes["office:time-value"]
                        ?? attributes["office:boolean-value"]
                        ?? ""
                    cellText = ""
                    cellRepeat = attributes["table:number-columns-repeated"].flatMap(Int.init) ?? 1
                    spannedCols = attributes["table:number-columns-spanned"].flatMap(Int.init) ?? 1
                    spannedRows = attributes["table:number-rows-spanned"].flatMap(Int.init) ?? 1
                case "text:p" where inCell:
                    // Each paragraph is a line of the cell's text.
                    if !cellText.isEmpty { cellText += "\n" }
                case "table:covered-table-cell" where sheet != nil:
                    // Merged-away slots still occupy a column.
                    column += min(attributes["table:number-columns-repeated"].flatMap(Int.init) ?? 1,
                                  SpreadsheetImporter.maxRepeat)
                default: break
                }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inCell { cellText += string }
            }
            func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
                switch element {
                case "style:style" where inAutomaticStyles:
                    if let autoName { styles[autoName] = (autoBold, autoItalic) }
                    autoName = nil
                case "office:automatic-styles": inAutomaticStyles = false
                case "table:table-cell" where sheet != nil:
                    inCell = false
                    let text: String
                    let kind: RawKind
                    switch cellValueType {
                    case "string":
                        text = cellText
                        kind = .text
                    case "float", "percentage", "currency":
                        text = cellValue.isEmpty ? "" : SpreadsheetImporter.numericDisplay(Double(cellValue) ?? 0)
                        kind = .number
                    case "date", "time":
                        // office:date-value / time-value are ISO 8601; render
                        // them the way a reader expects, not as raw stamps.
                        text = cellValue.isEmpty ? "" : SpreadsheetImporter.odsDateDisplay(cellValue)
                        kind = .text
                    case "duration":
                        // office:value is whole seconds.
                        text = cellValue.isEmpty ? ""
                            : (Double(cellValue).map(SpreadsheetImporter.durationDisplay(seconds:)) ?? cellValue)
                        kind = .text
                    case "boolean":
                        text = cellValue.isEmpty ? "" : (cellValue == "1" || cellValue.lowercased() == "true" ? "TRUE" : "FALSE")
                        kind = .boolean
                    default:
                        text = ""
                        kind = .text
                    }
                    let startCol = column
                    let repeats = min(cellRepeat, SpreadsheetImporter.maxRepeat)
                    // Empty repeats are grid padding: advance the column without
                    // materializing a cell per copy.
                    if text.isEmpty {
                        column += repeats
                    } else {
                        for _ in 0..<repeats {
                            sheet!.cells.append(RawCell(row: rowNumber, col: column, text: text,
                                                       kind: kind, styleName: cellStyle))
                            column += 1
                        }
                    }
                    if spannedCols > 1 || spannedRows > 1 {
                        sheet!.merges.append(RawMerge(row: rowNumber, col: startCol,
                                                      colspan: spannedCols, rowspan: spannedRows))
                    }
                case "table:table-row" where sheet != nil:
                    // A repeated row repeats its cells and its merges.
                    let repeats = min(rowRepeat, SpreadsheetImporter.maxRepeat)
                    let cellCount = sheet!.cells.count - rowCellStart
                    let mergeCount = sheet!.merges.count - rowMergeStart
                    for extra in 1..<repeats {
                        sheet!.cells.append(contentsOf: sheet!.cells[rowCellStart..<(rowCellStart + cellCount)])
                        for i in rowMergeStart..<rowMergeStart + mergeCount {
                            var m = sheet!.merges[i]
                            m.row += extra
                            sheet!.merges.append(m)
                        }
                    }
                    rowNumber += repeats
                case "table:table" where sheet != nil:
                    sheets.append(sheet!)
                    sheet = nil
                default: break
                }
            }
        }
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        let sheets = handler.sheets.map { (name: $0.name, cells: $0.cells, merges: $0.merges) }
        return (sheets, handler.styles)
    }
}

/// The two formats the importer reads; the menu exposes one entry per format
/// so each panel only accepts its own files.
enum SpreadsheetFormat: String {
    case xlsx
    case ods

    var type: UTType? { UTType(filenameExtension: rawValue) }
}

// File picking behind a protocol so tests script the chosen URLs instead of
// raising a panel; presents as a titlebar-anchored sheet like the CSV one.
protocol SpreadsheetFileImporting {
    func chooseSpreadsheetFiles(format: SpreadsheetFormat, prompt: String, into window: NSWindow?, completion: @escaping ([URL]?) -> Void)
}

struct SystemSpreadsheetImporter: SpreadsheetFileImporting {
    func chooseSpreadsheetFiles(format: SpreadsheetFormat, prompt: String, into window: NSWindow?, completion: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = false
        panel.allowedContentTypes = [format.type].compactMap { $0 }
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.urls : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.urls : nil)
        }
    }
}
