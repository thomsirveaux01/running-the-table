import SwiftUI

/// Rename sheet: the table's title is its file stem, so there is a single
/// field; committing moves the file and adopts whatever stem landed on disk.
struct RenameTablePrompt: View {
    @ObservedObject var viewModel: TableViewModel

    private var trimmedFileName: String {
        viewModel.renameFileNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Table")
                .font(.headline)
            HStack {
                TextField("File name", text: $viewModel.renameFileNameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 244)
                Text(".html")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { viewModel.cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { viewModel.commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedFileName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
