import Combine
import SwiftUI

struct CellView: View {
    @ObservedObject var viewModel: TableViewModel
    let row: Int
    let col: Int
    /// Visual column span of this slot, for drag selection with colspan.
    let startCol: Int
    let span: Int
    let width: CGFloat
    let height: CGFloat
    let visualCellAt: (NSPoint) -> VisualCell?

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
                isFocused: isFocused,
                cellCommands: { command in
                    let here = GridCell(row: row, column: col)
                    switch command {
                    case .addRowAbove: viewModel.addRow(adjacentTo: here, after: false)
                    case .addRowBelow: viewModel.addRow(adjacentTo: here, after: true)
                    case .addColumnLeft: viewModel.addColumn(adjacentTo: here, after: false)
                    case .addColumnRight: viewModel.addColumn(adjacentTo: here, after: true)
                    }
                },
                gridVisualOrigin: VisualCell(row: row, column: startCol),
                gridVisualSpan: span,
                visualCellAt: visualCellAt,
                cellRangeHandler: { viewModel.cellSelection = $0 },
                copyCells: { viewModel.copySelectedCells() },
                pasteTable: { viewModel.pasteTableFromPasteboardIfTable() }
            )
            .frame(width: width, height: height)
            // The selection border is one rectangle over the whole grid
            // (WYSIWYGView.selectionBorder), not per-cell.
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
