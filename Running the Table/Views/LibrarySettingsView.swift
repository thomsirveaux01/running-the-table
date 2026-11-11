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
                Spacer()
                Button("Done") { library.showSettings = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
