import AppKit

// View-layer HTML coloring for the source pane; consumed as temporary
// attributes, so stored text and the model never carry these colors.
enum HTMLHighlighter {
    // The tag-name branch keeps the leading < in its own group so brackets can
    // be muted VS Code-style; the < prefix also stops bare words from matching.
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"(?is)(<!--.*?-->)|(</?)([a-zA-Z][a-zA-Z0-9]*)|(/?>)|([a-zA-Z][a-zA-Z0-9-]*(?==))|("[^"]*"|'[^']*')|(&[#a-zA-Z0-9]+;)"#)

    // Alternation group -> color; dynamic system colors so light/dark adapt.
    private static let groupColors: [Int: NSColor] = [
        1: .tertiaryLabelColor,  // comment
        2: .secondaryLabelColor, // opening bracket
        3: .systemBlue,          // tag name
        4: .secondaryLabelColor, // closing bracket
        5: .systemTeal,          // attribute name
        6: .systemOrange,        // quoted value
        7: .systemPurple,        // entity
    ]

    static func colorRuns(in text: String) -> [(NSRange, NSColor)] {
        let ns = text as NSString
        var runs: [(NSRange, NSColor)] = []
        tokenPattern.enumerateMatches(in: text,
                                      range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            // Sorted: Dictionary key order is hash-seed randomized per
            // process, so unsorted iteration emitted runs in random order.
            for group in groupColors.keys.sorted() where match.range(at: group).location != NSNotFound {
                runs.append((match.range(at: group), groupColors[group]!))
            }
        }
        return runs
    }
}
