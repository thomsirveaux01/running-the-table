import AppKit
import Combine
import SwiftUI

// NSTextView wrapper (not TextEditor) so this pane shares the cells' undo
// stack instead of keeping a private one.
struct HTMLView: View {
    @ObservedObject var viewModel: TableViewModel

    private static let editorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var htmlContent: NSAttributedString {
        Self.liveContent(viewModel)
    }

    // Explicit foreground color: attributed strings lacking it render black
    // in dark mode.
    static func liveContent(_ viewModel: TableViewModel) -> NSAttributedString {
        NSAttributedString(string: viewModel.htmlText,
                           attributes: NSTextViewRepresentable.baseAttributes(font: editorFont))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HTML Source")
                    .font(.headline)
                Spacer()
                Button("Copy All") {
                    viewModel.copyHTMLToClipboard()
                }
                .help("Copy the full HTML to the clipboard")
            }
            .padding(8)
            Divider()
            // Hand-typed markup the parser could not honor says so here
            // instead of vanishing silently on the next regeneration.
            if !viewModel.markupDiagnostics.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.markupDiagnostics.first ?? "")
                        if viewModel.markupDiagnostics.count > 1 {
                            Text("plus \(viewModel.markupDiagnostics.count - 1) more markup issue(s)")
                                .font(.caption)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            NSTextViewRepresentable(
                content: htmlContent,
                contentRevision: viewModel.contentRevision,
                revision: viewModel.$contentRevision.eraseToAnyPublisher(),
                contentProvider: { Self.liveContent(viewModel) },
                isHeader: false,
                scrolls: true,
                font: Self.editorFont,
                undoManager: viewModel.undoManager,
                flushPendingEdits: { viewModel.closeTypingGroup() },
                onTextChange: { viewModel.importFromHTML($0.string) },
                onSelectionChange: { _ in },
                onFocus: {
                    // Leaving the grid commits any open typing run there.
                    viewModel.closeTypingGroup()
                },
                highlightsSyntax: true,
                showsLineNumbers: true,
                highlightsCurrentLine: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}
