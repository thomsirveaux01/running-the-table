import AppKit
import SwiftUI

/// The WYSIWYG grid entry point. The layout itself lives in TableGridView
/// (one AppKit document view with pooled cell editors); this wrapper keeps
/// the SwiftUI entry point the editor and the probes construct, and lists the
/// view-model properties whose changes must re-run the grid's sync. The
/// geometry constants and coordinate math below are the contract the
/// gridlayout/rowbound/handlepos probes pin.
struct WYSIWYGView: View {
    var viewModel: TableViewModel

    static let divider: CGFloat = 1
    static let handleThickness: CGFloat = 6
    static let gutterWidth: CGFloat = 22
    static let columnGutterHeight: CGFloat = 22
    static let captionHeight: CGFloat = 28
    /// How far a dragged strip's preview may lead the cursor; the offset
    /// eases toward min(raw translation, this), so slots glide instead of
    /// teleporting a whole row ahead of the pointer.
    static let followSlack: CGFloat = 8

    var body: some View {
        // Touch every property a layout change depends on: @Observable only
        // invalidates the view for properties read during body evaluation,
        // and TableGridView reads them later, inside updateNSView.
        _ = (viewModel.table, viewModel.columnWidths, viewModel.rowHeights,
             viewModel.contentRevision, viewModel.cellSelection,
             viewModel.focusedCell, viewModel.hasCaption)
        return TableGridView(viewModel: viewModel)
            .background(Color(NSColor.controlBackgroundColor))
    }

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

    /// Maps a point in the grid document view's top-origin coordinates (where
    /// drag events land) to a visual cell, clamped so drags into the gutters
    /// or past the far edges extend to the border cells. `captionOffset` is
    /// the vertical space the caption band pushes the grid down by.
    static func visualCell(at point: NSPoint, columnWidths: [CGFloat],
                           rowHeights: [CGFloat], captionOffset: CGFloat = 0) -> VisualCell? {
        guard !columnWidths.isEmpty, !rowHeights.isEmpty else { return nil }
        return VisualCell(row: axisIndex(point.y - (columnGutterHeight + 2 * divider + captionOffset), rowHeights),
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
}
