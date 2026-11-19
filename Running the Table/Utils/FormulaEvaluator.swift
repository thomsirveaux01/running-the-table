import Foundation

/// One-shot evaluation of xlsx formulas for files written without cached
/// results (Openpyxl and the like); cells with cached values keep them.
enum FormulaEvaluator {
    /// Fills the text of formula cells whose cache is empty; other cells pass
    /// through untouched. dateFormats maps a cellXfs slot to its Foundation
    /// date format (or nil), so date-styled results render as dates.
    static func fillMissingValues(in sheets: [(name: String, cells: [SpreadsheetImporter.RawCell])],
                                  dateFormats: [String?] = [])
        -> [(name: String, cells: [SpreadsheetImporter.RawCell])] {
        let evaluator = Evaluator(sheets: sheets)
        var out: [(name: String, cells: [SpreadsheetImporter.RawCell])] = []
        for (index, sheet) in sheets.enumerated() {
            var cells = sheet.cells
            for i in cells.indices where cells[i].formula != nil && cells[i].text.isEmpty {
                let value = evaluator.value(sheet: index, row: cells[i].row, col: cells[i].col)
                cells[i].text = display(value)
                // The serial stays in text so referencing formulas keep
                // working; only the display becomes a date.
                if case .number(let serial) = value,
                   let style = cells[i].styleIndex, dateFormats.indices.contains(style),
                   let format = dateFormats[style] {
                    cells[i].display = SpreadsheetImporter.dateDisplay(serial: serial, format: format)
                }
            }
            out.append((sheet.name, cells))
        }
        return out
    }

    /// The text a computed value lands up as in the imported table.
    static func display(_ value: CellValue) -> String {
        switch value {
        case .number(let d): return SpreadsheetImporter.numericDisplay(d)
        case .text(let s): return s
        case .boolean(let b): return b ? "TRUE" : "FALSE"
        case .error(let s): return s
        case .empty: return ""
        }
    }
}

/// A computed or stored cell value; errors carry Excel's display text.
enum CellValue {
    case number(Double)
    case text(String)
    case boolean(Bool)
    case error(String)
    case empty

    init(kind: SpreadsheetImporter.RawKind, text: String) {
        switch kind {
        case .number: self = .number(Double(text) ?? 0)
        case .boolean: self = .boolean(text == "1" || text.uppercased() == "TRUE")
        case .error: self = text.isEmpty ? .empty : .error(text)
        case .text: self = text.isEmpty ? .empty : .text(text)
        }
    }
}

/// Resolves refs and calls against the workbook's sheets; memoized, with
/// circular refs collapsing to empty like Excel's non-iterating default.
private final class Evaluator {
    private struct Entry {
        var value: CellValue
        var formula: String?
    }

    private let grids: [[Int: [Int: Entry]]]
    private let sheetIndex: [String: Int]
    private var memo: [UInt64: CellValue] = [:]
    private var inProgress: Set<UInt64> = []

    init(sheets: [(name: String, cells: [SpreadsheetImporter.RawCell])]) {
        var index: [String: Int] = [:]
        var grids: [[Int: [Int: Entry]]] = []
        for (i, sheet) in sheets.enumerated() {
            index[sheet.name.lowercased()] = i
            var grid: [Int: [Int: Entry]] = [:]
            for c in sheet.cells {
                grid[c.row, default: [:]][c.col] = Entry(value: CellValue(kind: c.kind, text: c.text),
                                                         formula: c.formula)
            }
            grids.append(grid)
        }
        self.grids = grids
        self.sheetIndex = index
    }

    func value(sheet: Int, row: Int, col: Int) -> CellValue {
        guard row >= 0, col >= 0, let entry = grids[sheet][row]?[col] else { return .empty }
        let key = Self.key(sheet, row, col)
        if let memoized = memo[key] { return memoized }
        guard let formula = entry.formula else {
            memo[key] = entry.value
            return entry.value
        }
        guard !inProgress.contains(key) else { return .empty }
        inProgress.insert(key)
        let result = FormulaParser.parse(formula).map { eval($0, sheet: sheet) } ?? .error("#NAME!")
        inProgress.remove(key)
        memo[key] = result
        return result
    }

    private static func key(_ sheet: Int, _ row: Int, _ col: Int) -> UInt64 {
        (UInt64(sheet) << 42) | (UInt64(row) << 21) | UInt64(col)
    }

    private func eval(_ node: Node, sheet: Int) -> CellValue {
        switch node {
        case .number(let d): return .number(d)
        case .string(let s): return .text(s)
        case .boolean(let b): return .boolean(b)
        case .ref(let name, let row, let col):
            let target = name.flatMap { sheetIndex[$0.lowercased()] } ?? sheet
            return value(sheet: target, row: row, col: col)
        // A bare range outside a function has no scalar value.
        case .range: return .error("#VALUE!")
        case .unary(let op, let arg):
            guard let n = number(eval(arg, sheet: sheet)) else { return .error("#VALUE!") }
            return .number(op == "-" ? -n : n)
        case .binary(let op, let l, let r):
            let lv = eval(l, sheet: sheet)
            let rv = eval(r, sheet: sheet)
            if case .error = lv { return lv }
            if case .error = rv { return rv }
            switch op {
            case "+", "-", "*", "^":
                guard let a = number(lv), let b = number(rv) else { return .error("#VALUE!") }
                switch op {
                case "+": return .number(a + b)
                case "-": return .number(a - b)
                case "*": return .number(a * b)
                default: return .number(pow(a, b))
                }
            case "/":
                guard let a = number(lv), let b = number(rv) else { return .error("#VALUE!") }
                guard b != 0 else { return .error("#DIV/0!") }
                return .number(a / b)
            case "&":
                return .text(FormulaEvaluator.display(lv) + FormulaEvaluator.display(rv))
            default:
                guard let cmp = compare(lv, rv) else { return .boolean(op == "<>") }
                switch op {
                case "=": return .boolean(cmp == 0)
                case "<>": return .boolean(cmp != 0)
                case "<": return .boolean(cmp < 0)
                case ">": return .boolean(cmp > 0)
                case "<=": return .boolean(cmp <= 0)
                case ">=": return .boolean(cmp >= 0)
                default: return .error("#VALUE!")
                }
            }
        case .call(let name, let args):
            return callFunction(name, args, sheet: sheet)
        }
    }

    /// Excel orders number < logical < text; empty compares as 0 or "".
    private func compare(_ a: CellValue, _ b: CellValue) -> Int? {
        switch (a, b) {
        case (.error, _), (_, .error): return nil
        case (.number(let x), .number(let y)): return x < y ? -1 : x > y ? 1 : 0
        case (.boolean(let x), .boolean(let y)): return x == y ? 0 : (x ? 1 : -1)
        case (.text(let x), .text(let y)):
            let lx = x.lowercased(), ly = y.lowercased()
            return lx < ly ? -1 : lx > ly ? 1 : 0
        case (.empty, .empty): return 0
        case (.empty, .number(let y)): return y > 0 ? -1 : y < 0 ? 1 : 0
        case (.number(let x), .empty): return x > 0 ? 1 : x < 0 ? -1 : 0
        case (.empty, .text(let y)): return y.isEmpty ? 0 : -1
        case (.text(let x), .empty): return x.isEmpty ? 0 : 1
        default:
            func rank(_ v: CellValue) -> Int {
                switch v {
                case .number: return 0
                case .boolean: return 1
                case .text: return 2
                default: return 3
                }
            }
            let ra = rank(a), rb = rank(b)
            return ra < rb ? -1 : ra > rb ? 1 : nil
        }
    }

    /// Excel's numeric coercion: empty is 0, logicals are 1/0, text is not a number.
    private func number(_ v: CellValue) -> Double? {
        switch v {
        case .number(let d): return d
        case .boolean(let b): return b ? 1 : 0
        case .empty: return 0
        case .text, .error: return nil
        }
    }

    private func callFunction(_ name: String, _ args: [Node], sheet: Int) -> CellValue {
        switch name.uppercased() {
        case "SUM", "AVERAGE", "COUNT", "COUNTA", "MIN", "MAX":
            let values = flatten(args, sheet: sheet)
            let nums = values.compactMap { if case .number(let d) = $0 { return d } else { return nil } }
            switch name.uppercased() {
            case "SUM":
                var total = 0.0
                for v in values {
                    if case .error = v { return v }
                    total += number(v) ?? 0
                }
                return .number(total)
            case "AVERAGE":
                guard !nums.isEmpty else { return .error("#DIV/0!") }
                return .number(nums.reduce(0, +) / Double(nums.count))
            case "COUNT":
                return .number(Double(nums.count))
            case "COUNTA":
                return .number(Double(values.filter { if case .empty = $0 { return false } else { return true } }.count))
            case "MIN":
                return .number(nums.min() ?? 0)
            default:
                return .number(nums.max() ?? 0)
            }
        case "SUMIF":
            return sumIf(args: args, sheet: sheet, sumFirst: false)
        case "SUMIFS":
            return sumIf(args: args, sheet: sheet, sumFirst: true)
        case "IF":
            guard args.count == 2 || args.count == 3 else { return .error("#VALUE!") }
            let cond = eval(args[0], sheet: sheet)
            if case .error = cond { return cond }
            let takeThen: Bool
            switch cond {
            case .number(let d): takeThen = d != 0
            case .boolean(let b): takeThen = b
            case .empty: takeThen = false
            case .text: return .error("#VALUE!")
            case .error: return cond
            }
            return takeThen ? eval(args[1], sheet: sheet)
                : (args.count == 3 ? eval(args[2], sheet: sheet) : .empty)
        case "IFERROR":
            guard args.count == 2 else { return .error("#VALUE!") }
            let v = eval(args[0], sheet: sheet)
            if case .error = v { return eval(args[1], sheet: sheet) }
            return v
        case "ROUND":
            guard args.count == 2, let x = number(eval(args[0], sheet: sheet)),
                  let digits = number(eval(args[1], sheet: sheet)) else { return .error("#VALUE!") }
            let f = pow(10, digits)
            return .number((x * f).rounded() / f)
        case "ABS":
            guard let x = number(eval(args[0], sheet: sheet)) else { return .error("#VALUE!") }
            return .number(abs(x))
        case "INT":
            guard let x = number(eval(args[0], sheet: sheet)) else { return .error("#VALUE!") }
            return .number(floor(x))
        default:
            return .error("#NAME!")
        }
    }

    /// SUMIF(range, crit, [sumRange]) or SUMIFS(sumRange, critRange, crit, …).
    private func sumIf(args: [Node], sheet: Int, sumFirst: Bool) -> CellValue {
        let sumCells: [CellValue]
        let pairs: [(range: Node, crit: Node)]
        if sumFirst {
            guard args.count >= 3, args.count % 2 == 1,
                  let cells = rangeCells(args[0], sheet: sheet) else { return .error("#VALUE!") }
            sumCells = cells
            var collected: [(Node, Node)] = []
            var i = 1
            while i + 1 < args.count {
                collected.append((args[i], args[i + 1]))
                i += 2
            }
            pairs = collected
        } else {
            guard args.count == 2 || args.count == 3,
                  let cells = rangeCells(args[0], sheet: sheet) else { return .error("#VALUE!") }
            sumCells = args.count == 3 ? (rangeCells(args[2], sheet: sheet) ?? []) : cells
            pairs = [(args[0], args[1])]
        }
        var mask = [Bool](repeating: true, count: sumCells.count)
        for pair in pairs {
            guard let critCells = rangeCells(pair.range, sheet: sheet),
                  critCells.count == sumCells.count else { return .error("#VALUE!") }
            let crit = eval(pair.crit, sheet: sheet)
            for j in mask.indices where mask[j] {
                mask[j] = matches(crit, critCells[j])
            }
        }
        var total = 0.0
        for j in sumCells.indices where mask[j] {
            if case .error = sumCells[j] { return sumCells[j] }
            total += number(sumCells[j]) ?? 0
        }
        return .number(total)
    }

    /// A criterion is a literal ("" matches empty) or an operator-prefixed
    /// comparison like ">100"; text compares case-insensitively.
    private func matches(_ crit: CellValue, _ cell: CellValue) -> Bool {
        switch crit {
        case .text(let s):
            if s.count > 1, let first = s.first, "=<>".contains(first) {
                let op = (s.hasPrefix(">=") || s.hasPrefix("<=") || s.hasPrefix("<>")) ? String(s.prefix(2)) : String(first)
                let operand = String(s.dropFirst(op.count))
                if let d = Double(operand) {
                    guard let n = number(cell) else { return false }
                    switch op {
                    case "=": return n == d
                    case "<>": return n != d
                    case ">": return n > d
                    case "<": return n < d
                    case ">=": return n >= d
                    case "<=": return n <= d
                    default: return false
                    }
                }
                let t = FormulaEvaluator.display(cell).lowercased()
                let o = operand.lowercased()
                switch op {
                case "=": return t == o
                case "<>": return t != o
                case ">": return t > o
                case "<": return t < o
                case ">=": return t >= o
                case "<=": return t <= o
                default: return false
                }
            }
            if s.isEmpty {
                if case .empty = cell { return true }
                if case .text(let t) = cell, t.isEmpty { return true }
                return false
            }
            if let d = Double(s) {
                if case .number(let n) = cell { return n == d }
                return false
            }
            if case .text(let t) = cell { return t.lowercased() == s.lowercased() }
            return false
        case .number(let d):
            if case .number(let n) = cell { return n == d }
            return false
        case .boolean(let b):
            if case .boolean(let c) = cell { return c == b }
            return false
        case .empty:
            if case .empty = cell { return true }
            return false
        case .error:
            return false
        }
    }

    /// Range args expand row-major; scalar args evaluate in place.
    private func flatten(_ args: [Node], sheet: Int) -> [CellValue] {
        var out: [CellValue] = []
        for arg in args {
            if let cells = rangeCells(arg, sheet: sheet) {
                out.append(contentsOf: cells)
            } else {
                out.append(eval(arg, sheet: sheet))
            }
        }
        return out
    }

    private func rangeCells(_ arg: Node, sheet: Int) -> [CellValue]? {
        guard case .range(let name, let r1, let c1, let r2, let c2) = arg else { return nil }
        let target = name.flatMap { sheetIndex[$0.lowercased()] } ?? sheet
        var out: [CellValue] = []
        for r in r1...r2 {
            for c in c1...c2 {
                out.append(value(sheet: target, row: r, col: c))
            }
        }
        return out
    }
}

/// Parsed formula tree; sheet-qualified refs carry the source sheet name.
private indirect enum Node {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case ref(sheet: String?, row: Int, col: Int)
    case range(sheet: String?, r1: Int, c1: Int, r2: Int, c2: Int)
    case unary(String, Node)
    case binary(String, Node, Node)
    case call(String, [Node])
}

/// Tokenizer plus recursive-descent parser with Excel's operator precedence
/// (comparisons loosest, ^ right-associative above unary minus).
private enum FormulaParser {
    private enum Tok {
        case number(Double)
        case string(String)
        case ident(String)
        case boolean(Bool)
        case ref(sheet: String?, row: Int, col: Int)
        case op(String)
        case lparen
        case rparen
        case comma
        case colon
    }

    static func parse(_ text: String) -> Node? {
        guard let tokens = tokenize(text), !tokens.isEmpty else { return nil }
        var i = 0
        guard let node = comparison(tokens, &i), i == tokens.count else { return nil }
        return node
    }

    private static func tokenize(_ text: String) -> [Tok]? {
        var tokens: [Tok] = []
        var chars = Array(text)
        var i = 0
        while true {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            guard i < chars.count else { break }
            let c = chars[i]
            if c == "'" {
                // Quoted sheet name; '' inside quotes is a literal quote.
                i += 1
                var name = ""
                var closed = false
                while i < chars.count {
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" { name.append("'"); i += 2; continue }
                        closed = true
                        i += 1
                        break
                    }
                    name.append(chars[i])
                    i += 1
                }
                guard closed, i < chars.count, chars[i] == "!" else { return nil }
                i += 1
                guard let ref = cellRef(&chars, &i) else { return nil }
                tokens.append(.ref(sheet: name, row: ref.row, col: ref.col))
            } else if c == "\"" {
                i += 1
                var s = ""
                var closed = false
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" { s.append("\""); i += 2; continue }
                        closed = true
                        i += 1
                        break
                    }
                    s.append(chars[i])
                    i += 1
                }
                guard closed else { return nil }
                tokens.append(.string(s))
            } else if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var num = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." { num.append(chars[i]); i += 1 }
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var exp = String(chars[i])
                    i += 1
                    if i < chars.count, chars[i] == "+" || chars[i] == "-" { exp.append(chars[i]); i += 1 }
                    if i < chars.count, chars[i].isNumber {
                        while i < chars.count, chars[i].isNumber { exp.append(chars[i]); i += 1 }
                        num += exp
                    }
                }
                guard let d = Double(num) else { return nil }
                tokens.append(.number(d))
            } else if c == "$" {
                guard let ref = cellRef(&chars, &i) else { return nil }
                tokens.append(.ref(sheet: nil, row: ref.row, col: ref.col))
            } else if c.isLetter || c == "_" {
                var word = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    word.append(chars[i])
                    i += 1
                }
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == "!" {
                    // A word followed by ! is a sheet name, not a function.
                    i = j + 1
                    guard let ref = cellRef(&chars, &i) else { return nil }
                    tokens.append(.ref(sheet: word, row: ref.row, col: ref.col))
                } else if word.uppercased() == "TRUE" || word.uppercased() == "FALSE" {
                    tokens.append(.boolean(word.uppercased() == "TRUE"))
                } else if let ref = decomposeRef(word) {
                    tokens.append(.ref(sheet: nil, row: ref.row, col: ref.col))
                } else {
                    tokens.append(.ident(word))
                }
            } else if c == "<", i + 1 < chars.count, chars[i + 1] == ">" || chars[i + 1] == "=" {
                tokens.append(.op(String(chars[i...i + 1])))
                i += 2
            } else if c == ">", i + 1 < chars.count, chars[i + 1] == "=" {
                tokens.append(.op(">="))
                i += 2
            } else {
                switch c {
                case "+", "-", "*", "/", "^", "&", "=":
                    tokens.append(.op(String(c))); i += 1
                case "(":
                    tokens.append(.lparen); i += 1
                case ")":
                    tokens.append(.rparen); i += 1
                case ",":
                    tokens.append(.comma); i += 1
                case ":":
                    tokens.append(.colon); i += 1
                case "<", ">":
                    tokens.append(.op(String(c))); i += 1
                default:
                    return nil
                }
            }
        }
        return tokens
    }

    /// Reads an optional-$, letters, optional-$, digits reference from the stream.
    private static func cellRef(_ chars: inout [Character], _ i: inout Int) -> (row: Int, col: Int)? {
        if i < chars.count, chars[i] == "$" { i += 1 }
        var word = ""
        while i < chars.count, chars[i].isLetter { word.append(chars[i]); i += 1 }
        if i < chars.count, chars[i] == "$" { i += 1 }
        while i < chars.count, chars[i].isNumber { word.append(chars[i]); i += 1 }
        return decomposeRef(word)
    }

    /// "C2" → (1, 1); letters must precede digits, so "SUM" and "2C" reject.
    private static func decomposeRef(_ word: String) -> (row: Int, col: Int)? {
        var col = 0
        var rowText = ""
        var seenDigit = false
        for ch in word {
            guard let v = ch.asciiValue else { return nil }
            if (65...90).contains(v) || (97...122).contains(v) {
                guard !seenDigit else { return nil }
                col = col * 26 + Int((65...90).contains(v) ? v - 64 : v - 96)
            } else if (48...57).contains(v) {
                seenDigit = true
                rowText.append(ch)
            } else {
                return nil
            }
        }
        guard col > 0, let row = Int(rowText), row > 0 else { return nil }
        return (row - 1, col - 1)
    }

    private static func comparison(_ t: [Tok], _ i: inout Int) -> Node? {
        guard var left = concat(t, &i) else { return nil }
        while i < t.count, case let .op(o) = t[i], ["=", "<>", "<", ">", "<=", ">="].contains(o) {
            i += 1
            guard let right = concat(t, &i) else { return nil }
            left = .binary(o, left, right)
        }
        return left
    }

    private static func concat(_ t: [Tok], _ i: inout Int) -> Node? {
        guard var left = add(t, &i) else { return nil }
        while i < t.count, case .op("&") = t[i] {
            i += 1
            guard let right = add(t, &i) else { return nil }
            left = .binary("&", left, right)
        }
        return left
    }

    private static func add(_ t: [Tok], _ i: inout Int) -> Node? {
        guard var left = mul(t, &i) else { return nil }
        while i < t.count, case let .op(o) = t[i], o == "+" || o == "-" {
            i += 1
            guard let right = mul(t, &i) else { return nil }
            left = .binary(o, left, right)
        }
        return left
    }

    private static func mul(_ t: [Tok], _ i: inout Int) -> Node? {
        guard var left = unary(t, &i) else { return nil }
        while i < t.count, case let .op(o) = t[i], o == "*" || o == "/" {
            i += 1
            guard let right = unary(t, &i) else { return nil }
            left = .binary(o, left, right)
        }
        return left
    }

    private static func unary(_ t: [Tok], _ i: inout Int) -> Node? {
        if i < t.count, case let .op(o) = t[i], o == "-" || o == "+" {
            i += 1
            guard let operand = unary(t, &i) else { return nil }
            return o == "-" ? .unary("-", operand) : operand
        }
        return power(t, &i)
    }

    private static func power(_ t: [Tok], _ i: inout Int) -> Node? {
        guard let base = primary(t, &i) else { return nil }
        if i < t.count, case .op("^") = t[i] {
            i += 1
            guard let exponent = unary(t, &i) else { return nil }
            return .binary("^", base, exponent)
        }
        return base
    }

    private static func primary(_ t: [Tok], _ i: inout Int) -> Node? {
        guard i < t.count else { return nil }
        let tok = t[i]
        i += 1
        switch tok {
        case .number(let d): return .number(d)
        case .string(let s): return .string(s)
        case .boolean(let b): return .boolean(b)
        case .ref(let sheet, let row, let col):
            if i < t.count, case .colon = t[i] {
                i += 1
                guard i < t.count, case let .ref(s2, r2, c2) = t[i] else { return nil }
                i += 1
                // A sheet on either side applies to the whole range.
                return .range(sheet: sheet ?? s2,
                              r1: min(row, r2), c1: min(col, c2),
                              r2: max(row, r2), c2: max(col, c2))
            }
            return .ref(sheet: sheet, row: row, col: col)
        case .ident(let name):
            guard i < t.count, case .lparen = t[i] else { return nil }
            i += 1
            var args: [Node] = []
            if i < t.count, case .rparen = t[i] {
                i += 1
            } else {
                while true {
                    guard let arg = comparison(t, &i) else { return nil }
                    args.append(arg)
                    guard i < t.count else { return nil }
                    if case .comma = t[i] { i += 1; continue }
                    if case .rparen = t[i] { i += 1; break }
                    return nil
                }
            }
            return .call(name, args)
        case .lparen:
            guard let inner = comparison(t, &i), i < t.count, case .rparen = t[i] else { return nil }
            i += 1
            return inner
        default:
            return nil
        }
    }
}
