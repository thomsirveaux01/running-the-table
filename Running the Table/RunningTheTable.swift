import SwiftUI

@main struct RunningTheTable: App {
    // @State holds @Observable models; the Observation-era replacement for @StateObject.
    @State private var viewModel = TableViewModel()
    @State private var updater = UpdateChecker()
    @State private var library = LibraryCoordinator()

    // The flag is static and read when a window orders on screen, so it has to
    // go before WindowGroup builds anything.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // ⌘N belongs to New Table, so the stock New Window rides ⌥⌘N via the
        // user-defaults remap AppKit re-applies on every menu rebuild.
        UserDefaults.standard.set(["New Window": "@~n"], forKey: "NSUserKeyEquivalents")
        // Click rescue: if a plain single mouse-up produced no selection request within
        // 150 ms (List ate it mid-reconcile), route the clicked table row's document directly.
        let vm = viewModel
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { e in
            // Rescue main-window clicks only, and never while a sheet is up: the
            // save/open panels' file browsers are NSTableViews too, and menu
            // tracking delivers stray windows whose coords land on sidebar rows.
            if e.clickCount == 1,
               e.modifierFlags.isDisjoint(with: [.command, .shift, .option]),
               let win = e.window, win === (NSApp.keyWindow ?? NSApp.mainWindow),
               win.attachedSheet == nil {
                let pt = e.locationInWindow
                let seen = SidebarClickGuard.requestCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard SidebarClickGuard.requestCount == seen,
                          let content = win.contentView,
                          let hit = content.hitTest(content.convert(pt, from: nil)) else { return }
                    var v: NSView? = hit
                    while let cur = v, !(cur is NSTableRowView) { v = cur.superview }
                    guard let rowView = v as? NSTableRowView else { return }
                    var t: NSView? = rowView.superview
                    while let cur = t, !(cur is NSTableView) { t = cur.superview }
                    guard let table = t as? NSTableView else { return }
                    let idx = table.row(for: rowView)
                    guard idx >= 0, idx < vm.documents.count else { return }
                    vm.requestSidebarSelection([vm.documents[idx].id])
                }
            }
            return e
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, updater: updater, library: library)
                // Library launch work lives here, not in ContentView, so
                // test harnesses hosting ContentView never touch the panel.
                .task {
                    library.viewModel = viewModel
                    library.launchOnce()
                }
        }
        .commands {
            RunningTheTableCommands(viewModel: viewModel, updater: updater, library: library)
        }
        // No Settings scene by design: Settings… opens a floating NSWindow of
        // its own (see commands), so no stray SwiftUI windows.
    }
}
