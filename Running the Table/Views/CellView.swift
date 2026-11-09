import Combine
import SwiftUI

struct CellView: View {
    @ObservedObject var viewModel: TableViewModel
    let row: Int
    let col: Int
    let width: CGFloat
    let height: CGFloat

    private var isFocused: Bool {
        viewModel.focusedCell == GridCell(row: row, column: col)
    }

    var body: some View {
        // Looked up through the view model so stale updates can't subscript
        // out of bounds.
        if let cell = viewModel.cell(row: row, col: col) {
            NSTextViewRepresentable(
                content: cell.content,
                contentRevision: viewModel.contentRevision,
                revision: viewModel.$contentRevision.eraseToAnyPublisher(),
                contentProvider: { viewModel.cell(row: row, col: col)?.content ?? NSAttributedString() },
                isHeader: cell.isHeader,
                undoManager: viewModel.undoManager,
                flushPendingEdits: { viewModel.closeTypingGroup() },
                onTextChange: { viewModel.updateCellContent(row: row, col: col, $0) },
                onSelectionChange: { viewModel.updateCellSelection(row: row, col: col, $0) },
                onFocus: { viewModel.focusedCell = GridCell(row: row, column: col) },
                onGridKey: { viewModel.handleGridKey($0, from: GridCell(row: row, column: col)) },
                isFocused: isFocused
            )
            .frame(width: width, height: height)
            .overlay(
                Rectangle()
                    .strokeBorder(
                        isFocused ? Color.accentColor : Color(NSColor.separatorColor),
                        lineWidth: isFocused ? 2 : 1
                    )
                    .allowsHitTesting(false)
            )
        } else {
            Color.clear
                .frame(width: width, height: height)
        }
    }
}
