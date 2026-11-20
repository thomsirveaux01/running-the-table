import AppKit
import SwiftUI

/// A real floating window so Settings can sit beside the main window.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not coded")
    }

    func show(library: LibraryCoordinator, updater: UpdateChecker) {
        if window == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            // Matches the stock Settings-scene title ("App Name Settings").
            window.title = "Running the Table Settings"
            window.level = .floating
            window.isReleasedWhenClosed = false
            // The hosting controller sizes the window to the view's fixed width.
            window.contentViewController = NSHostingController(
                rootView: LibrarySettingsView(library: library, updater: updater))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
