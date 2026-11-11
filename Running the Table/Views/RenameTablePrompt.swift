import SwiftUI

/// Rename sheet: the title is the source of truth and the .html filename is
/// derived from it, so the filename is shown (updating live) but not edited.
struct RenameTablePrompt: View {
    @ObservedObject var viewModel: TableViewModel

    private var trimmedTitle: String {
        viewModel.renameTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Table")
                .font(.headline)
            TextField("Title", text: $viewModel.renameTitleText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack(spacing: 4) {
                Text(viewModel.renameFileNameDisplay)
                    .foregroundStyle(.secondary)
                Text(".html")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 280, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { viewModel.commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(16)
    }
}
