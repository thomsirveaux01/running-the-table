import AppKit
import SwiftUI

struct LibrarySettingsView: View {
    var library: LibraryCoordinator
    var updater: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            folderSection
            Divider()
            versionSection
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 28)
        .frame(width: 520)
    }

    // The path wraps to as many lines as needed so the whole folder is always visible.
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tables Folder:")
                .fontWeight(.semibold)
            Text(library.currentPath)
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LibraryLocation.directory])
                }
                Button("Change…") { library.changeFolder() }
            }
        }
    }

    // The caption and Download button persist after the update prompt is dismissed or skipped.
    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Version:")
                .fontWeight(.semibold)
            HStack(spacing: 6) {
                Text(updater.currentVersion)
                if let build = Self.buildVersion {
                    Text("· build \(build)")
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            // Always one caption line (blank when current) so the section's
            // height stays constant.
            Text(updateCaption ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
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
