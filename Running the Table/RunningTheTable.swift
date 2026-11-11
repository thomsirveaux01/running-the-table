import SwiftUI

@main struct RunningTheTable: App {
    @StateObject private var viewModel = TableViewModel()
    @StateObject private var updater = UpdateChecker()
    @StateObject private var library = LibraryCoordinator()

    // The flag is static and read when a window orders on screen, so it has to
    // go before WindowGroup builds anything.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // ⌘N belongs to New Table, so the stock New Window rides ⌥⌘N via the
        // user-defaults remap AppKit re-applies on every menu rebuild.
        UserDefaults.standard.set(["New Window": "@~n"], forKey: "NSUserKeyEquivalents")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, updater: updater, library: library)
                // Library launch work lives here, not in ContentView, so
                // offscreen probes hosting ContentView never touch the panel.
                .task {
                    library.viewModel = viewModel
                    library.launchOnce()
                }
        }
        .commands {
            RunningTheTableCommands(viewModel: viewModel, updater: updater, library: library)
        }
        // No Settings scene by design: Settings… raises a sheet on the main
        // window (see commands), so no stray windows.
    }
}
