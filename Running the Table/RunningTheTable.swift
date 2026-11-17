import SwiftUI

@main struct RunningTheTable: App {
    // @State holds the @Observable model (the Observation-era replacement
    // for @StateObject; @Observable does not conform to ObservableObject).
    @State private var viewModel = TableViewModel()
    @StateObject private var updater = UpdateChecker()
    @StateObject private var library = LibraryCoordinator()

    // The flag is static and read when a window orders on screen, so it has to
    // go before WindowGroup builds anything.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // ⌘N belongs to New Table, so the stock New Window rides ⌥⌘N via the
        // user-defaults remap AppKit re-applies on every menu rebuild.
        UserDefaults.standard.set(["New Window": "@~n"], forKey: "NSUserKeyEquivalents")
        // TEMP RTSWITCH: age of each click at dispatch — the time between the
        // hardware event and the app getting to it (queue backlog included).
        // Plus a rescue backstop: if a plain sidebar mouse-up produces no
        // selection request within 150 ms (List swallowed it mid-reconcile),
        // hit-test the click point, find the enclosing table row, and route
        // its document directly.
        let vm = viewModel
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            let age = (ProcessInfo.processInfo.systemUptime - e.timestamp) * 1000
            NSLog(String(format: "RTSWITCH %@ t=%.1f age=%.1fms clicks=%d loc=%@",
                         e.type == .leftMouseDown ? "down" : "up",
                         ProcessInfo.processInfo.systemUptime * 1000, age, e.clickCount,
                         NSStringFromPoint(e.locationInWindow)))
            if e.type == .leftMouseUp, e.clickCount == 1,
               e.modifierFlags.isDisjoint(with: [.command, .shift, .option]) {
                let win = e.window
                let pt = e.locationInWindow
                let seen = RTSwitchTrace.requestCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard RTSwitchTrace.requestCount == seen,
                          let content = win?.contentView,
                          let hit = content.hitTest(content.convert(pt, from: nil)) else { return }
                    var v: NSView? = hit
                    while let cur = v, !(cur is NSTableRowView) { v = cur.superview }
                    guard let rowView = v as? NSTableRowView else { return }
                    var t: NSView? = rowView.superview
                    while let cur = t, !(cur is NSTableView) { t = cur.superview }
                    guard let table = t as? NSTableView else { return }
                    let idx = table.row(for: rowView)
                    guard idx >= 0, idx < vm.documents.count else { return }
                    RTSwitchTrace.log("rescue row=\(idx)")
                    vm.requestSidebarSelection([vm.documents[idx].id], src: "rescue")
                }
            }
            return e
        }
        // TEMP RTSWITCH: 10 ms heartbeat — any gap > 60 ms is main-thread
        // work nobody stamped, in the user's own session. Common modes so
        // mouse-tracking (button held) does not fake a gap.
        let beat = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = RTSwitchTrace.now
            defer { RTSwitchTrace.lastBeat = now }
            if RTSwitchTrace.lastBeat > 0, now - RTSwitchTrace.lastBeat > 60 {
                NSLog(String(format: "RTSWITCH beat gap=%.0fms", now - RTSwitchTrace.lastBeat))
            }
        }
        RunLoop.main.add(beat, forMode: .common)
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
