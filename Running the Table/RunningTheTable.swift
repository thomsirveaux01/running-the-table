import SwiftUI

@main struct RunningTheTable: App {
    @StateObject private var viewModel = TableViewModel()

    // The flag is static and read when a window orders on screen, so it has to
    // go before WindowGroup builds anything.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .commands {
            RunningTheTableCommands(viewModel: viewModel)
        }
    }
}
