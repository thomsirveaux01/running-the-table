import AppKit
import SwiftUI

/// The app's whole menu-bar additions, in one Commands value so the
/// menu-reading probes can compile the identical commands into a test app.
struct RunningTheTableCommands: Commands {
    @ObservedObject var viewModel: TableViewModel
    // Defaulted so menu probes compile the identical commands unchanged.
    @ObservedObject var updater: UpdateChecker = UpdateChecker()
    @ObservedObject var library: LibraryCoordinator = LibraryCoordinator()

    var body: some Commands {
        // The stock About item, re-issued so the panel gets our credits block.
        CommandGroup(replacing: .appInfo) {
            Button("About Running the Table") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: AboutPanel.credits])
            }
            Button("Check for Updates…") {
                Task { await updater.check(userInitiated: true) }
            }
        }

        // Settings is an in-app sheet, so the stock window slot must raise it.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { library.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        // ⌘N lands above the stock New Window (remapped to ⌥⌘N in App's
        // init); a replaced .newItem group would delete New Window, and an
        // id-carrying WindowGroup never opens its launch window.
        CommandGroup(before: .newItem) {
            Button("New Table") { viewModel.newTable() }
                .keyboardShortcut("n")
        }

        // The submenu needs a disabled placeholder while no template
        // exists: .disabled() on a Menu is ignored.
        CommandGroup(after: .newItem) {
            Button("Rename Table…") { viewModel.beginRename() }
                .keyboardShortcut("r")
                .disabled(viewModel.selectedDocumentID == nil)

            Divider()

            Menu("New from Template") {
                if viewModel.templates.isEmpty {
                    Button("No Templates") {}.disabled(true)
                } else {
                    ForEach(viewModel.sortedTemplates) { template in
                        Button(template.name) { viewModel.newTable(fromTemplate: template) }
                    }
                }
            }

            // ⇧⌘S is the standard Save As chord: a template is a saved variant.
            Button("Save as Template…") { viewModel.beginTemplateSave() }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(viewModel.selectedDocumentID == nil)

            // Submenus leave room for Markdown and friends later; Export needs
            // a live table, Import works with none selected.
            Divider()

            Menu("Import") {
                Button("CSV…") { viewModel.importCSV() }
            }

            Menu("Export") {
                Button("CSV…") { viewModel.exportCSV() }
                    .disabled(viewModel.selectedDocumentID == nil)
            }
        }

        // Stock undo:/redo: dispatch down the responder chain, which only cell
        // text views answer; driving the manager works from any focus.
        CommandGroup(replacing: .undoRedo) {
            Button(viewModel.undoManager.undoMenuItemTitle) {
                viewModel.undoFromMenu()
            }
            .keyboardShortcut("z")
            .disabled(!viewModel.undoManager.canUndo)

            Button(viewModel.undoManager.redoMenuItemTitle) {
                viewModel.redoFromMenu()
            }
            .keyboardShortcut("Z", modifiers: [.command, .shift])
            .disabled(!viewModel.undoManager.canRedo)
        }

        // Chord family: the arrow names the edge, and ⌥⌘ keeps it clear of
        // NSTextView's ⌥/⌘ caret motions. CommandMenu has no placement knob.
        CommandMenu("Insert") {
            Button("Add Row Above") { insertRow(after: false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(viewModel.focusedCell == nil)

            Button("Add Row Below") { insertRow(after: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(viewModel.focusedCell == nil)

            Button("Add Column Left") { insertColumn(after: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(viewModel.focusedCell == nil)

            Button("Add Column Right") { insertColumn(after: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(viewModel.focusedCell == nil)

            // The remove chords moved off the toolbar so they are printed
            // somewhere; tr+/td+ keep ⌘⌥R and ⌘⌥C.
            Divider()

            Button("Remove Row") { viewModel.removeRow() }
                .keyboardShortcut("R", modifiers: [.command, .option, .shift])
                .disabled(viewModel.focusedCell == nil || viewModel.table.rows.count <= 1
                          || !(viewModel.focusedCell.map { viewModel.canRemoveRow($0.row) } ?? false))

            Button("Remove Column") { viewModel.removeColumn() }
                .keyboardShortcut("C", modifiers: [.command, .option, .shift])
                .disabled(viewModel.focusedCell == nil || viewModel.table.columnCount <= 1
                          || !viewModel.canRemoveFocusedColumn)

            Divider()

            Button("Add Link…") { viewModel.beginLinkEntry() }
                .keyboardShortcut("k")
                .disabled(viewModel.focusedCell == nil)

            Divider()

            Button(viewModel.hasCaption ? "Hide Caption" : "Show Caption") {
                viewModel.toggleCaption()
            }
        }

        // The formatting commands duplicate the toolbar buttons, but only a
        // menu prints its key equivalent, so the chords live here.
        CommandGroup(after: .textFormatting) {
            Toggle("Bold", isOn: viewModel.boldBinding)
                .keyboardShortcut("b")
                .disabled(viewModel.focusedCell == nil)

            Toggle("Italic", isOn: viewModel.italicBinding)
                .keyboardShortcut("i")
                .disabled(viewModel.focusedCell == nil)

            Toggle("Header Cell", isOn: viewModel.headerBinding)
                .keyboardShortcut("H", modifiers: [.command, .shift])
                .disabled(viewModel.focusedCell == nil)

            Divider()

            Menu("Colspan") {
                ForEach(TableCell.minColspan...TableCell.maxColspan, id: \.self) { span in
                    Button {
                        viewModel.colspanBinding.wrappedValue = span
                    } label: {
                        if viewModel.colspanBinding.wrappedValue == span {
                            Label("\(span)", systemImage: "checkmark")
                        } else {
                            Text("\(span)")
                        }
                    }
                    // .disabled() on the Menu itself is ignored in a
                    // CommandMenu, so grey out each leaf instead.
                    .disabled(viewModel.focusedCell == nil)
                }
            }

            Menu("Align") {
                ForEach([NSTextAlignment.left, .center, .right], id: \.self) { alignment in
                    Button {
                        viewModel.setAlignment(alignment)
                    } label: {
                        if viewModel.alignment == alignment {
                            Label(alignment.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(alignment.menuTitle)
                        }
                    }
                    // The Cocoa-standard alignment chords; only the menu prints
                    // them, so they live on these items, not the toolbar pills.
                    .keyboardShortcut(KeyEquivalent(alignment.alignKey), modifiers: .command)
                    .disabled(viewModel.focusedCell == nil)
                }
            }

            Divider()

            Button("Merge Cells") { viewModel.mergeSelection() }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(!viewModel.canMergeSelection)

            Button("Split Cells") { viewModel.splitFocusedCell() }
                .keyboardShortcut("M", modifiers: [.command, .option, .shift])
                .disabled(!viewModel.canSplitFocused)

            Menu("Row Section") {
                ForEach([RowSection.head, .body, .foot], id: \.self) { section in
                    Button {
                        viewModel.setFocusedRowSection(section)
                    } label: {
                        if viewModel.focusedRowSection == section {
                            Label(section.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(section.menuTitle)
                        }
                    }
                    .disabled(viewModel.focusedCell == nil)
                }
            }
        }

        // Rides after the stock Paste group: a second .pasteboard group is
        // dropped, and leaving Undo/Redo alone keeps Cut/Copy/Paste under it.
        CommandGroup(after: .pasteboard) {
            Button("Paste as New Table") {
                viewModel.pasteAsNewTable()
            }
            .keyboardShortcut("V", modifiers: [.command, .shift])

            Divider()

            Button("Duplicate Table") {
                viewModel.duplicateSelectedDocument()
            }
            .keyboardShortcut("d")
            .disabled(viewModel.selectedDocumentIDs.isEmpty)

            Button("Duplicate Row") {
                viewModel.duplicateRow()
            }
            .disabled(!viewModel.canDuplicateFocusedRow)

            Button("Duplicate Column") {
                viewModel.duplicateColumn()
            }
            .disabled(!viewModel.canDuplicateFocusedColumn)

            // Greyed while a text view owns the caret — except during a cell
            // block, where the chord must reach the action to clear the block
            // (a disabled item would swallow it).
            Button(viewModel.cellSelection == nil ? "Delete Table" : "Delete Cells") {
                viewModel.deleteTableChordPressed()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(viewModel.selectedDocumentIDs.isEmpty
                      || (viewModel.isEditingText && viewModel.cellSelection == nil))

            Divider()

            Button("Manage Templates…") { viewModel.showTemplateManager = true }

            // ⌘1 mirrors Excel's Format Cells: a dialog that formats the
            // current table.
            Button("Table Attributes…") { viewModel.beginTableAttributes() }
                .keyboardShortcut("1")
                .disabled(viewModel.selectedDocumentID == nil)
        }
    }

    // Menu-bar variants anchor on focus, unlike the context menu's clicked cell.
    private func insertRow(after: Bool) {
        guard let f = viewModel.focusedCell else { return }
        viewModel.addRow(adjacentTo: f, after: after)
    }

    private func insertColumn(after: Bool) {
        guard let f = viewModel.focusedCell else { return }
        viewModel.addColumn(adjacentTo: f, after: after)
    }
}

/// Credits block for the standard About panel, kept separate so probes can
/// assert its payload without ordering the panel on screen.
enum AboutPanel {
    static let githubURLString = "https://github.com/thomsirveaux01/running-the-table"

    // The link attribute makes "GitHub" clickable in the panel's text view.
    static var credits: NSAttributedString {
        let text = "Andrew Cunningham, 2026\n\nVibe-coded locally with open-weight Apache 2.0 models on Apple Silicon Macs\n\nGitHub"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // Extra line space between the wrapped lines of the credits paragraph.
        paragraph.lineSpacing = 2.0
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph,
        ])
        if let url = URL(string: githubURLString) {
            let range = (text as NSString).range(of: "GitHub")
            credits.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: range)
        }
        return credits
    }
}
