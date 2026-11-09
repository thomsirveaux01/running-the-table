import SwiftUI

@main struct RunningTheTable: App {
    @StateObject private var viewModel = TableViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .commands {
            // No key equivalent: a Delete shortcut would hijack keystrokes
            // the cells need for text editing.
            CommandGroup(after: .undoRedo) {
                Button("Delete Table") {
                    viewModel.deleteSelectedDocument()
                }
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
            }
        }
    }
}
