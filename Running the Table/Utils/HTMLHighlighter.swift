import AppKit

// View-layer HTML coloring for the source pane; consumed as temporary
// attributes, so stored text and the model never carry these colors.
enum HTMLHighlighter {
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"(?is)(<!--.*?-->)|(</?[a-zA-Z][a-zA-Z0-9]*)|(/?>)|([a-zA-Z][a-zA-Z0-9-]*(?==))|("[^"]*"|'[^']*')|(&[#a-zA-Z0-9]+;)"#)

    // Alternation group -> color; dynamic system colors so light/dark adapt.
    private static let groupColors: [Int: NSColor] = [
        1: .tertiaryLabelColor,  // comment
        2: .systemBlue,          // tag
        3: .systemBlue,          // tag punctuation
        4: .systemTeal,          // attribute name
        5: .systemOrange,        // quoted value
        6: .systemPurple,        // entity
    ]

    static func colorRuns(in text: String) -> [(NSRange, NSColor)] {
        let ns = text as NSString
        var runs: [(NSRange, NSColor)] = []
        tokenPattern.enumerateMatches(in: text,
                                      range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            for group in groupColors.keys where match.range(at: group).location != NSNotFound {
                runs.append((match.range(at: group), groupColors[group]!))
            }
        }
        return runs
    }
}
