import AppKit
import Combine
import SwiftUI

struct WYSIWYGView: View {
    @ObservedObject var viewModel: TableViewModel

    static let divider: CGFloat = 1
    static let handleThickness: CGFloat = 6
    static let gutterWidth: CGFloat = 22
    static let columnGutterHeight: CGFloat = 22

    // Drag state lives outside the view model so gesture updates never churn
    // autosave or the undo stack.
    @StateObject private var dragState = RowDragState()
    @StateObject private var columnDragState = ColumnDragState()

    private struct CellSlot {
        let index: Int
        let startCol: Int
        let span: Int
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: Self.divider) {
                HStack(spacing: Self.divider) {
                    Color(NSColor.controlBackgroundColor)
                        .frame(width: Self.gutterWidth, height: Self.columnGutterHeight)
                    ForEach(viewModel.columnWidths.indices, id: \.self) { col in
                        ColumnMoveHandle(viewModel: viewModel, dragState: columnDragState, col: col)
                            .frame(width: columnWidth(col), height: Self.columnGutterHeight)
                            .offset(x: columnShift(col))
                            .opacity(columnDragState.draggedCol == col ? 0.5 : 1)
                            .zIndex(isColLifted(col) ? 1 : 0)
                            .shadow(color: Color.black.opacity(isColLifted(col) ? 0.25 : 0),
                                    radius: isColLifted(col) ? 8 : 0,
                                    x: isColLifted(col) ? 3 : 0)
                    }
                }
                HStack(spacing: Self.divider) {
                    VStack(spacing: Self.divider) {
                        ForEach(viewModel.table.rows.indices, id: \.self) { row in
                            RowMoveHandle(viewModel: viewModel, dragState: dragState, row: row)
                                .frame(width: Self.gutterWidth, height: rowHeight(row))
                                .offset(y: rowOffset(row))
                                .zIndex(isLifted(row) ? 1 : 0)
                        }
                    }
                    VStack(spacing: Self.divider) {
                        ForEach(viewModel.table.rows.indices, id: \.self) { row in
                            rowView(row)
                                .opacity(dragState.draggedRow == row ? 0.5 : 1)
                                .offset(y: rowOffset(row))
                                .zIndex(isLifted(row) ? 1 : 0)
                                .shadow(color: Color.black.opacity(isLifted(row) ? 0.25 : 0),
                                        radius: isLifted(row) ? 8 : 0,
                                        y: isLifted(row) ? 3 : 0)
                        }
                    }
                }
            }
            .padding(Self.divider)
            // The separator color shows through the 1pt spacing as grid lines.
            .background(Color(NSColor.separatorColor))
            .overlay(alignment: .topLeading) { resizeHandles }
            .overlay(alignment: .topLeading) { gapHighlight }
            .overlay(alignment: .topLeading) { columnGapHighlight }
            .overlay(alignment: .topLeading) { selectionBorder }
            // Keyed on previewTick (fires only on landing-slot changes) so
            // the dragged item tracks the cursor 1:1 between bumps.
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: dragState.previewTick)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: columnDragState.previewTick)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func rowHeight(_ row: Int) -> CGFloat {
        row < viewModel.rowHeights.count ? viewModel.rowHeights[row] : TableViewModel.defaultRowHeight
    }

    /// Rows between source and landing slot slide aside; the grabbed row
    /// rides the opened gap, rubber-banded to the cursor.
    private func rowOffset(_ row: Int) -> CGFloat {
        if dragState.draggedRow == row {
            let target = dragState.targetRow ?? row
            let gap = Self.slotTop(source: row, target: target, rowHeights: viewModel.rowHeights)
            let desired = rowTop(row) + dragState.translation
            let slack = min(max(desired - gap, -Self.followSlack), Self.followSlack)
            return gap + slack - rowTop(row)
        }
        if dragState.settleRow == row { return dragState.settleOffset }
        guard let source = dragState.draggedRow,
              let target = dragState.targetRow,
              target != source else { return 0 }
        let step = rowHeight(source) + Self.divider
        if target > source, row > source, row <= target { return -step }
        if target < source, row >= target, row < source { return step }
        return 0
    }

    /// How far the dragged row may stray from the gap before it sticks.
    static let followSlack: CGFloat = 8

    /// Slot the dragged row rides in; moving down the gap opens under the
    /// target, moving up it opens over the target.
    static func slotTop(source: Int, target: Int, rowHeights: [CGFloat]) -> CGFloat {
        func top(_ i: Int) -> CGFloat {
            divider + rowHeights.prefix(i).reduce(0, +) + CGFloat(i) * divider
        }
        func height(_ i: Int) -> CGFloat {
            i < rowHeights.count ? rowHeights[i] : TableViewModel.defaultRowHeight
        }
        guard target != source else { return top(source) }
        let step = height(source) + divider
        if target > source { return top(target) + height(target) + divider - step }
        return top(target)
    }

    private func isLifted(_ row: Int) -> Bool {
        if dragState.draggedRow == row { return true }
        return dragState.settleRow == row && abs(dragState.settleOffset) > 0.5
    }

    private func columnShift(_ col: Int) -> CGFloat {
        if columnDragState.draggedCol == col {
            let target = columnDragState.targetCol ?? col
            let gap = Self.slotLeft(source: col, target: target, widths: viewModel.columnWidths)
            let desired = columnLeft(col) + columnDragState.translation
            let slack = min(max(desired - gap, -Self.followSlack), Self.followSlack)
            return gap + slack - columnLeft(col)
        }
        if columnDragState.settleCol == col { return columnDragState.settleOffset }
        guard let source = columnDragState.draggedCol,
              let target = columnDragState.targetCol,
              target != source else { return 0 }
        let step = columnWidth(source) + Self.divider
        if target > source, col > source, col <= target { return -step }
        if target < source, col >= target, col < source { return step }
        return 0
    }

    private func columnWidth(_ col: Int) -> CGFloat {
        col < viewModel.columnWidths.count ? viewModel.columnWidths[col] : TableViewModel.defaultColumnWidth
    }

    /// Left edge of a column in pre-shift layout coordinates; offsets are
    /// differences, so the row gutter's width cancels out.
    private func columnLeft(_ col: Int) -> CGFloat {
        guard col > 0, col < viewModel.columnWidths.count else { return Self.divider }
        return Self.divider + viewModel.columnWidths[0..<col].reduce(0, +)
            + CGFloat(col) * Self.divider
    }

    /// Slot the dragged column rides in; moving right the gap opens past
    /// the target, moving left it opens over the target.
    static func slotLeft(source: Int, target: Int, widths: [CGFloat]) -> CGFloat {
        func left(_ i: Int) -> CGFloat {
            divider + widths.prefix(i).reduce(0, +) + CGFloat(i) * divider
        }
        func width(_ i: Int) -> CGFloat {
            i < widths.count ? widths[i] : TableViewModel.defaultColumnWidth
        }
        guard target != source else { return left(source) }
        let step = width(source) + divider
        if target > source { return left(target) + width(target) + divider - step }
        return left(target)
    }

    private func isColLifted(_ col: Int) -> Bool {
        if columnDragState.draggedCol == col { return true }
        return columnDragState.settleCol == col && abs(columnDragState.settleOffset) > 0.5
    }

    @ViewBuilder
    private func rowView(_ row: Int) -> some View {
        let cells = viewModel.table.rows[row]
        HStack(spacing: Self.divider) {
            ForEach(slots(for: cells), id: \.index) { slot in
                CellView(
                    viewModel: viewModel,
                    row: row,
                    col: slot.index,
                    startCol: slot.startCol,
                    span: slot.span,
                    width: viewModel.cellWidth(startingAtCol: slot.startCol, span: slot.span),
                    height: row < viewModel.rowHeights.count
                        ? viewModel.rowHeights[row]
                        : TableViewModel.defaultRowHeight,
                    visualCellAt: {
                        Self.visualCell(at: $0, columnWidths: viewModel.columnWidths,
                                        rowHeights: viewModel.rowHeights)
                    }
                )
                // A colspan cell slides as a unit with its columns.
                .offset(x: columnShift(slot.startCol))
                .opacity(columnDragState.draggedCol == slot.startCol ? 0.5 : 1)
                .zIndex(isColLifted(slot.startCol) ? 1 : 0)
                .shadow(color: Color.black.opacity(isColLifted(slot.startCol) ? 0.25 : 0),
                        radius: isColLifted(slot.startCol) ? 8 : 0,
                        x: isColLifted(slot.startCol) ? 3 : 0)
            }
        }
    }

    private func slots(for row: [TableCell]) -> [CellSlot] {
        var slots: [CellSlot] = []
        var position = 0
        for (index, cell) in row.enumerated() {
            let span = min(max(cell.colspan, TableCell.minColspan), TableCell.maxColspan)
            slots.append(CellSlot(index: index, startCol: position, span: span))
            position += span
        }
        return slots
    }

    private var gridColumnsWidth: CGFloat {
        viewModel.columnWidths.reduce(0, +)
            + CGFloat(max(viewModel.columnWidths.count - 1, 0)) * Self.divider
    }

    private var gridHeight: CGFloat {
        2 * Self.divider + viewModel.rowHeights.reduce(0, +)
            + CGFloat(max(viewModel.rowHeights.count - 1, 0)) * Self.divider
    }

    /// Cell columns begin past the row gutter inside the padded container.
    private var gridLeftEdge: CGFloat {
        Self.divider + Self.gutterWidth + Self.divider
    }

    /// Row content begins below the column gutter strip.
    private var gridTopEdge: CGFloat {
        Self.divider + Self.columnGutterHeight + Self.divider
    }

    @ViewBuilder
    private var resizeHandles: some View {
        ForEach(0..<max(viewModel.columnWidths.count - 1, 0), id: \.self) { column in
            // Hidden where a colspan cell covers the boundary.
            if viewModel.canResizeBoundary(afterCol: column) {
                ColumnResizeHandle(viewModel: viewModel, column: column)
                    .frame(width: Self.handleThickness, height: gridHeight)
                    .offset(x: columnBoundaryX(column) - Self.handleThickness / 2,
                            y: gridTopEdge)
            }
        }
        ForEach(0..<max(viewModel.rowHeights.count - 1, 0), id: \.self) { row in
            RowResizeHandle(viewModel: viewModel, row: row)
                .frame(width: gridColumnsWidth, height: Self.handleThickness)
                .offset(x: gridLeftEdge, y: rowBoundaryY(row) - Self.handleThickness / 2)
            }
    }

    // Accent fill marking the slot the dragged row rides in.
    @ViewBuilder
    private var gapHighlight: some View {
        if let source = dragState.draggedRow, let target = dragState.targetRow, target != source {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: Self.gutterWidth + Self.divider + gridColumnsWidth,
                       height: rowHeight(source) + Self.divider)
                .offset(x: Self.divider,
                        y: Self.slotTop(source: source, target: target, rowHeights: viewModel.rowHeights)
                            + Self.columnGutterHeight + Self.divider)
                .allowsHitTesting(false)
        }
    }

    // Accent fill marking the slot the dragged column rides in.
    @ViewBuilder
    private var columnGapHighlight: some View {
        if let source = columnDragState.draggedCol, let target = columnDragState.targetCol, target != source {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: columnWidth(source) + Self.divider,
                       height: Self.columnGutterHeight + gridHeight)
                .offset(x: gridLeftEdge - Self.divider
                            + Self.slotLeft(source: source, target: target, widths: viewModel.columnWidths),
                        y: Self.divider)
                .allowsHitTesting(false)
        }
    }

    /// One continuous accent border around the selected cell rectangle, drawn
    /// in the padded-container space the resize handles use.
    @ViewBuilder
    private var selectionBorder: some View {
        if let rect = selectionRect {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// Bounding box of every slot intersecting the selection, so a colspan
    /// cell that straddles the range edge is enclosed rather than cut.
    private var selectionRect: CGRect? {
        guard let sel = viewModel.cellSelection, !viewModel.table.rows.isEmpty else { return nil }
        var left = CGFloat.greatestFiniteMagnitude, right = -CGFloat.greatestFiniteMagnitude
        var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
        for row in sel.rowStart...sel.rowEnd where viewModel.table.rows.indices.contains(row) {
            for slot in slots(for: viewModel.table.rows[row])
            where sel.intersects(row: row, startCol: slot.startCol, span: slot.span) {
                left = min(left, columnEdge(slot.startCol))
                // columnEdge past the last covered column lands a divider late.
                right = max(right, columnEdge(slot.startCol + slot.span) - Self.divider)
            }
            top = min(top, rowEdge(row))
            bottom = max(bottom, rowEdge(row + 1) - Self.divider)
        }
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Leading edge of visual column i (i == count gives the trailing edge).
    private func columnEdge(_ i: Int) -> CGFloat {
        var x = gridLeftEdge
        for j in 0..<min(i, viewModel.columnWidths.count) { x += columnWidth(j) + Self.divider }
        return x
    }

    /// Top edge of visual row j (j == count gives the bottom edge).
    private func rowEdge(_ j: Int) -> CGFloat {
        var y = gridTopEdge
        for k in 0..<min(j, viewModel.rowHeights.count) { y += rowHeight(k) + Self.divider }
        return y
    }

    /// Top edge of a row in pre-shift layout coordinates.
    private func rowTop(_ row: Int) -> CGFloat {
        guard row > 0, row < viewModel.rowHeights.count else { return Self.divider }
        return Self.divider + viewModel.rowHeights[0..<row].reduce(0, +)
            + CGFloat(row) * Self.divider
    }

    /// Maps a point in the grid document view's top-origin coordinates (where
    /// drag events land) to a visual cell, clamped so drags into the gutters
    /// or past the far edges extend to the border cells.
    static func visualCell(at point: NSPoint, columnWidths: [CGFloat],
                           rowHeights: [CGFloat]) -> VisualCell? {
        guard !columnWidths.isEmpty, !rowHeights.isEmpty else { return nil }
        return VisualCell(row: axisIndex(point.y - (columnGutterHeight + 2 * divider), rowHeights),
                          column: axisIndex(point.x - (gutterWidth + 2 * divider), columnWidths))
    }

    private static func axisIndex(_ offset: CGFloat, _ sizes: [CGFloat]) -> Int {
        var remaining = offset
        var index = 0
        while index < sizes.count - 1, remaining >= sizes[index] + divider {
            remaining -= sizes[index] + divider
            index += 1
        }
        return index
    }

    private func columnBoundaryX(_ column: Int) -> CGFloat {
        guard column < viewModel.columnWidths.count else { return 0 }
        let widths = viewModel.columnWidths[0...column]
        return gridLeftEdge + widths.reduce(0, +) + CGFloat(column) * Self.divider + Self.divider / 2
    }

    private func rowBoundaryY(_ row: Int) -> CGFloat {
        guard row < viewModel.rowHeights.count else { return 0 }
        let heights = viewModel.rowHeights[0...row]
        return gridTopEdge + heights.reduce(0, +) + CGFloat(row) * Self.divider + Self.divider / 2
    }
}

// One undo step per completed drag.
struct ColumnResizeHandle: View {
    @ObservedObject var viewModel: TableViewModel
    let column: Int
    @State private var startWidth: CGFloat?
    @State private var beforeSnapshot: EditorSnapshot?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if startWidth == nil {
                            startWidth = column < viewModel.columnWidths.count
                                ? viewModel.columnWidths[column]
                                : TableViewModel.defaultColumnWidth
                            beforeSnapshot = viewModel.currentSnapshot()
                        }
                        if let base = startWidth {
                            viewModel.setColumnWidth(column, to: base + value.translation.width)
                        }
                    }
                    .onEnded { _ in
                        startWidth = nil
                        if let before = beforeSnapshot {
                            viewModel.registerResizeUndo(name: "Resize Column", before: before)
                        }
                        beforeSnapshot = nil
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

struct RowResizeHandle: View {
    @ObservedObject var viewModel: TableViewModel
    let row: Int
    @State private var startHeight: CGFloat?
    @State private var beforeSnapshot: EditorSnapshot?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if startHeight == nil {
                            startHeight = row < viewModel.rowHeights.count
                                ? viewModel.rowHeights[row]
                                : TableViewModel.defaultRowHeight
                            beforeSnapshot = viewModel.currentSnapshot()
                        }
                        if let base = startHeight {
                            viewModel.setRowHeight(row, to: base + value.translation.height)
                        }
                    }
                    .onEnded { _ in
                        startHeight = nil
                        if let before = beforeSnapshot {
                            viewModel.registerResizeUndo(name: "Resize Row", before: before)
                        }
                        beforeSnapshot = nil
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }
}

// Kept out of the view model so drag updates never touch autosave.
final class RowDragState: ObservableObject {
    @Published var draggedRow: Int?
    @Published var targetRow: Int?
    @Published var translation: CGFloat = 0
    /// Bumped on landing-slot changes; the grid's spring is keyed on it.
    @Published var previewTick = 0
    /// Row easing into its slot after a drop, plus its shrinking offset.
    @Published var settleRow: Int?
    @Published var settleOffset: CGFloat = 0

    func reset() {
        draggedRow = nil
        targetRow = nil
        translation = 0
    }
}

// Drag the strip to move its row; the drop commits as one undo step.
struct RowMoveHandle: View {
    @ObservedObject var viewModel: TableViewModel
    @ObservedObject var dragState: RowDragState
    let row: Int
    @State private var beforeSnapshot: EditorSnapshot?
    @State private var hovering = false

    private var isDragged: Bool { dragState.draggedRow == row }

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isDragged ? Color.accentColor : Color.secondary.opacity(hovering ? 0.9 : 0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isDragged ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor))
            .contentShape(Rectangle())
            .gesture(
                // Global space: the grip shifts during the drag, and local
                // space would feed that shift back into the translation.
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        if beforeSnapshot == nil {
                            beforeSnapshot = viewModel.currentSnapshot()
                            dragState.settleRow = nil
                            dragState.settleOffset = 0
                            dragState.draggedRow = row
                        }
                        dragState.translation = value.translation.height
                        let landing = landingIndex(translationY: value.translation.height)
                        if dragState.targetRow != landing {
                            dragState.previewTick += 1
                            dragState.targetRow = landing
                        }
                    }
                    .onEnded { value in
                        guard let before = beforeSnapshot else {
                            dragState.reset()
                            return
                        }
                        beforeSnapshot = nil
                        let dy = value.translation.height
                        let dest = landingIndex(translationY: dy)
                        // The row's current visual top, per rowOffset's math.
                        let gap = WYSIWYGView.slotTop(source: row, target: dest,
                                                      rowHeights: viewModel.rowHeights)
                        let slack = min(max(rowTop(row) + dy - gap, -WYSIWYGView.followSlack),
                                        WYSIWYGView.followSlack)
                        let visualTop = gap + slack
                        viewModel.moveRow(from: row, to: dest, before: before)
                        // The commit relays rows instantly; pin the row at
                        // its visual position, then spring it to its new slot.
                        dragState.settleRow = dest
                        dragState.settleOffset = visualTop - rowTop(dest)
                        dragState.reset()
                        DispatchQueue.main.async {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                dragState.settleOffset = 0
                            } completion: {
                                dragState.settleRow = nil
                            }
                        }
                    }
            )
            .onHover { hovering in
                self.hovering = hovering
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("Drag to move this row")
    }

    private func rowTop(_ index: Int) -> CGFloat {
        let divider = WYSIWYGView.divider
        var y = divider
        for i in 0..<min(max(index, 0), viewModel.rowHeights.count) {
            y += viewModel.rowHeights[i] + divider
        }
        return y
    }

    /// Landing row for a drop at `translationY`: count row centers above the
    /// drag point; dragging down past the row's own center reserves below.
    private func landingIndex(translationY dy: CGFloat) -> Int {
        let divider = WYSIWYGView.divider
        let count = max(viewModel.table.rows.count, 1)
        func height(_ i: Int) -> CGFloat {
            i < viewModel.rowHeights.count ? viewModel.rowHeights[i] : TableViewModel.defaultRowHeight
        }
        var ownCenter = divider
        for i in 0..<min(row, count) { ownCenter += height(i) + divider }
        ownCenter += height(min(row, count - 1)) / 2
        let dragPoint = ownCenter + dy
        var above = 0
        var y = divider
        for i in 0..<count {
            if y + height(i) / 2 < dragPoint { above += 1 }
            y += height(i) + divider
        }
        let index = dy > 0 ? above - 1 : above
        return min(max(index, 0), count - 1)
    }
}

final class ColumnDragState: ObservableObject {
    @Published var draggedCol: Int?
    @Published var targetCol: Int?
    @Published var translation: CGFloat = 0
    /// Bumped on landing-slot changes; the grid's spring is keyed on it.
    @Published var previewTick = 0
    /// Column easing into its slot after a drop, plus its shrinking offset.
    @Published var settleCol: Int?
    @Published var settleOffset: CGFloat = 0

    func reset() {
        draggedCol = nil
        targetCol = nil
        translation = 0
    }
}

// Drag the strip to move its column. Colspan-covered columns show a blank
// strip: they can't move cleanly, so they stay un-grabbable.
struct ColumnMoveHandle: View {
    @ObservedObject var viewModel: TableViewModel
    @ObservedObject var dragState: ColumnDragState
    let col: Int
    @State private var beforeSnapshot: EditorSnapshot?
    @State private var hovering = false

    private var isDragged: Bool { dragState.draggedCol == col }

    var body: some View {
        Group {
            if viewModel.canMoveColumn(col) {
                // Rotated row grip: "line.3.vertical" is not a real SF Symbol
                // name, so the horizontal one turns to stand in.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(isDragged ? Color.accentColor : Color.secondary.opacity(hovering ? 0.9 : 0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(isDragged ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor))
                    .contentShape(Rectangle())
                    .gesture(
                        // Global space: the grip shifts during the drag, and local
                        // space would feed that shift back into the translation.
                        DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { value in
                                if beforeSnapshot == nil {
                                    beforeSnapshot = viewModel.currentSnapshot()
                                    dragState.settleCol = nil
                                    dragState.settleOffset = 0
                                    dragState.draggedCol = col
                                }
                                dragState.translation = value.translation.width
                                let landing = landingIndex(translationX: value.translation.width)
                                if dragState.targetCol != landing {
                                    dragState.previewTick += 1
                                    dragState.targetCol = landing
                                }
                            }
                            .onEnded { value in
                                guard let before = beforeSnapshot else {
                                    dragState.reset()
                                    return
                                }
                                beforeSnapshot = nil
                                let dx = value.translation.width
                                let dest = landingIndex(translationX: dx)
                                // The column's current visual left, per columnShift's math.
                                let gap = WYSIWYGView.slotLeft(source: col, target: dest,
                                                                widths: viewModel.columnWidths)
                                let slack = min(max(columnLeft(col) + dx - gap, -WYSIWYGView.followSlack),
                                                WYSIWYGView.followSlack)
                                let visualLeft = gap + slack
                                viewModel.moveColumn(from: col, to: dest, before: before)
                                // The commit relays columns instantly; pin the column at
                                // its visual position, then spring it to its new slot.
                                dragState.settleCol = dest
                                dragState.settleOffset = visualLeft - columnLeft(dest)
                                dragState.reset()
                                DispatchQueue.main.async {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                        dragState.settleOffset = 0
                                    } completion: {
                                        dragState.settleCol = nil
                                    }
                                }
                            }
                    )
                    .onHover { hovering in
                        self.hovering = hovering
                        if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .help("Drag to move this column")
            } else {
                Color(NSColor.controlBackgroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columnWidth(_ index: Int) -> CGFloat {
        index < viewModel.columnWidths.count ? viewModel.columnWidths[index] : TableViewModel.defaultColumnWidth
    }

    private func columnLeft(_ index: Int) -> CGFloat {
        let divider = WYSIWYGView.divider
        var x = divider
        for i in 0..<min(max(index, 0), viewModel.columnWidths.count) {
            x += viewModel.columnWidths[i] + divider
        }
        return x
    }

    /// Landing column for a drop at `translationX`: count column centers left
    /// of the drag point; dragging right past the column's own center reserves
    /// the slot on the right.
    private func landingIndex(translationX dx: CGFloat) -> Int {
        let divider = WYSIWYGView.divider
        let count = max(viewModel.columnWidths.count, 1)
        func width(_ i: Int) -> CGFloat {
            i < viewModel.columnWidths.count ? viewModel.columnWidths[i] : TableViewModel.defaultColumnWidth
        }
        var ownCenter = divider
        for i in 0..<min(col, count) { ownCenter += width(i) + divider }
        ownCenter += width(min(col, count - 1)) / 2
        let dragPoint = ownCenter + dx
        var leftOf = 0
        var x = divider
        for i in 0..<count {
            if x + width(i) / 2 < dragPoint { leftOf += 1 }
            x += width(i) + divider
        }
        let index = dx > 0 ? leftOf - 1 : leftOf
        return min(max(index, 0), count - 1)
    }
}
