import SwiftUI

@main struct RunningTheTable: App {
    @StateObject private var viewModel = TableViewModel()
    @StateObject private var updater = UpdateChecker()

    // The flag is static and read when a window orders on screen, so it has to
    // go before WindowGroup builds anything.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // ⌘N belongs to New Table, so the stock New Window item moves to
        // ⌥⌘N through the same user-defaults remap System Settings writes
        // ("@" = ⌘, "~" = ⌥); AppKit re-applies it on every menu rebuild.
        UserDefaults.standard.set(["New Window": "@~n"], forKey: "NSUserKeyEquivalents")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, updater: updater)
        }
        .commands {
            RunningTheTableCommands(viewModel: viewModel, updater: updater)
        }
    }
}
