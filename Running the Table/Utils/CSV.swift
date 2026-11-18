import AppKit
import Foundation
import UniformTypeIdentifiers

// RFC 4180 CSV: fields are delimiter-separated, records end on CRLF, LF, or bare CR, and
// a double-quoted field may contain "" quotes, delimiters, and newlines. The parser is
// lenient about junk after a closing quote; the encoder quotes only when needed.

enum CSV {
    private static let cr = Unicode.Scalar(13)!
    private static let lf = Unicode.Scalar(10)!
    private static let quote = Unicode.Scalar(34)!

    // Scalars, not Characters: Swift folds a CRLF into one grapheme cluster,
    // so a Character scan would never see the bare \r of a CRLF record end.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        guard let delim = delimiter.unicodeScalars.first else { return [] }
        var chars = Array(text.unicodeScalars)
        var i = 0
        var rows: [[String]] = []
        while i < chars.count {
            var row: [String] = []
            while true {
                row.append(readField(&chars, &i, delim, cr, lf, quote))
                guard i < chars.count else { break }
                if chars[i] == cr {
                    i += 1
                    if i < chars.count && chars[i] == lf { i += 1 }
                    break
                } else if chars[i] == lf {
                    i += 1
                    break
                } else if chars[i] == delim {
                    i += 1
                }
            }
            rows.append(row)
        }
        return rows
    }

    static func encode(_ rows: [[String]], delimiter: Character = ",") -> String {
        var out = ""
        for (r, row) in rows.enumerated() {
            if r > 0 { out += "\n" }
            for (c, field) in row.enumerated() {
                if c > 0 { out.append(delimiter) }
                out += encodeField(field, delimiter)
            }
        }
        return out
    }

    // Quote only when the field holds the delimiter, a quote, or a newline; double
    // embedded quotes. Newlines are checked as scalars: CRLF is one grapheme cluster.
    private static func encodeField(_ field: String, _ delimiter: Character) -> String {
        let scalars = field.unicodeScalars
        guard field.contains(delimiter) || field.contains("\"")
            || scalars.contains(cr) || scalars.contains(lf) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func readField(_ chars: inout [Unicode.Scalar], _ i: inout Int,
                                  _ delim: Unicode.Scalar, _ cr: Unicode.Scalar,
                                  _ lf: Unicode.Scalar, _ quote: Unicode.Scalar) -> String {
        var field = ""
        if i < chars.count && chars[i] == quote {
            i += 1
            while i < chars.count {
                if chars[i] == quote {
                    if i + 1 < chars.count && chars[i + 1] == quote {
                        field.append(Character(quote))
                        i += 2
                    } else {
                        i += 1
                        break
                    }
                } else {
                    field.append(Character(chars[i]))
                    i += 1
                }
            }
            // Lenient: junk after the closing quote joins the field rather than being dropped.
            while i < chars.count, chars[i] != delim, chars[i] != lf, chars[i] != cr {
                field.append(Character(chars[i]))
                i += 1
            }
        } else {
            while i < chars.count, chars[i] != delim, chars[i] != lf, chars[i] != cr {
                field.append(Character(chars[i]))
                i += 1
            }
        }
        return field
    }
}

// File picking behind protocols so tests script the chosen URL instead of raising a
// panel. Both present as titlebar-anchored window-modal sheets via beginSheetModal.

protocol CSVFileImporting {
    func chooseCSVFile(prompt: String, into window: NSWindow?, completion: @escaping (URL?) -> Void)
}

protocol CSVFileExporting {
    func chooseCSVFile(prompt: String, suggestedName: String, defaultURL: URL?,
                       into window: NSWindow?, completion: @escaping (URL?) -> Void)
}

/// The .plainText in each import panel is conformance-wide — md and csv both
/// conform to it — so a delegate greys out the other importer's type. TXT passes both.
final class ImportPanelFilter: NSObject, NSOpenSavePanelDelegate {
    enum Kind { case csv, markdown }
    private static let markdownTypes: [UTType] =
        [UTType(filenameExtension: "md"), UTType("public.markdown")].compactMap { $0 }
    private let kind: Kind
    init(kind: Kind) { self.kind = kind }

    static func allows(_ url: URL, kind: Kind) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return true }
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .plainText
        switch kind {
        case .csv: return !markdownTypes.contains { type.conforms(to: $0) }
        case .markdown: return !type.conforms(to: .commaSeparatedText)
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { Self.allows(url, kind: kind) }

    // Panels hold their delegate weakly; process-lifetime singletons keep them alive.
    static let csv = ImportPanelFilter(kind: .csv)
    static let markdown = ImportPanelFilter(kind: .markdown)
}

struct SystemCSVImporter: CSVFileImporting {
    func chooseCSVFile(prompt: String, into window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.delegate = ImportPanelFilter.csv
        // Anchored to the key window when there is one; the panel then slides
        // down from its titlebar instead of floating as a separate window.
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

struct SystemCSVExporter: CSVFileExporting {
    func chooseCSVFile(prompt: String, suggestedName: String, defaultURL: URL?,
                       into window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.prompt = prompt
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        panel.allowedContentTypes = [.commaSeparatedText]
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
