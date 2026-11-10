import SwiftUI

/// The app's whole menu-bar additions, in one Commands value so the
/// menu-reading probes can compile the identical commands into a test app.
struct RunningTheTableCommands: Commands {
    @ObservedObject var viewModel: TableViewModel

    var body: some Commands {
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
            Menu("New from Template") {
                if viewModel.templates.isEmpty {
                    Button("No Templates") {}.disabled(true)
                } else {
                    ForEach(viewModel.sortedTemplates) { template in
                        Button(template.name) { viewModel.newTable(fromTemplate: template) }
                    }
                }
            }

            Button("Save as Template…") { viewModel.beginTemplateSave() }
                .disabled(viewModel.selectedDocumentID == nil)
        }

        // Stock items dispatch undo:/redo: down the responder chain, where
        // only cell text views answer — dead whenever focus is elsewhere.
        // Driving the manager directly works from any focus position.
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

            // A second CommandGroup anchored on .undoRedo is dropped, so the
            // table commands live in this one.
            Divider()

            Button("Duplicate Table") {
                viewModel.duplicateSelectedDocument()
            }
            .keyboardShortcut("d")
            .disabled(viewModel.selectedDocumentID == nil)

            // Greyed while a text view owns the caret; the action also hands
            // the chord back, because disabled items still swallow it.
            Button("Delete Table") {
                viewModel.deleteTableChordPressed()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(viewModel.selectedDocumentID == nil || viewModel.isEditingText)

            Divider()

            Button("Manage Templates…") { viewModel.showTemplateManager = true }
        }

        // Apple Notes' table chord family (⌥⌘+arrows): the arrow names the
        // edge, and ⌥⌘ keeps it clear of NSTextView's ⌥/⌘ caret motions.
        // CommandMenu has no placement knob, so this lands after View.
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
                .disabled(viewModel.focusedCell == nil || viewModel.table.rows.count <= 1)

            Button("Remove Column") { viewModel.removeColumn() }
                .keyboardShortcut("C", modifiers: [.command, .option, .shift])
                .disabled(viewModel.focusedCell == nil || viewModel.table.columnCount <= 1)

            Divider()

            // Ellipsis: the command opens the URL sheet, per macOS convention.
            Button("Add Link…") { viewModel.beginLinkEntry() }
                .keyboardShortcut("k")
                .disabled(viewModel.focusedCell == nil)
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
        }

        // Sits after the stock Paste group; ⌘V still pastes text into a
        // cell, this turns the pasteboard into a whole new table.
        CommandGroup(after: .pasteboard) {
            Button("Paste as New Table") {
                viewModel.pasteAsNewTable()
            }
            .keyboardShortcut("V", modifiers: [.command, .shift])
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
