import AppKit
import SwiftUI

struct LibrarySettingsView: View {
    @ObservedObject var library: LibraryCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tables Folder").font(.headline)
            Text(library.currentPath)
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
            HStack {
                Button("Change…") { library.changeFolder() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LibraryLocation.directory])
                }
            }
            Text("Templates live in a Templates subfolder here. Point the folder at iCloud Drive, Dropbox, or any synced location and your tables sync with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520)
    }
}
