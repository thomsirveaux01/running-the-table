import AppKit
import SwiftUI

struct LibrarySettingsView: View {
    var library: LibraryCoordinator
    var updater: UpdateChecker

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
            Divider()
            versionRow
        }
        .padding(20)
        .frame(width: 520)
    }

    // The current version, plus a caption and Download button that persist
    // after the update prompt is dismissed or skipped.
    private var versionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Version").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(updater.currentVersion)
                    if let build = Self.buildVersion {
                        Text("· build \(build)")
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                // Always one caption line (blank when current) so the row's
                // height stays constant.
                Text(updateCaption ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if updater.availableUpdate != nil {
                Button("Download") {
                    Task { await updater.downloadAvailableUpdate() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var updateCaption: String? {
        guard let release = updater.availableUpdate else { return nil }
        return "Version \(UpdateChecker.normalizedTag(release.tagName)) is available."
    }

    private static var buildVersion: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}
