import SwiftUI

/// Rename sheet: the visible title and the .html filename are separate
/// fields because a saved table's path is sticky (see saveAllDocuments) and
/// the title is app-side metadata that never enters the HTML.
struct RenameTablePrompt: View {
    @ObservedObject var viewModel: TableViewModel

    private var trimmedTitle: String {
        viewModel.renameTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedFileName: String {
        viewModel.renameFileNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Table")
                .font(.headline)
            TextField("Title", text: $viewModel.renameTitleText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                TextField("File name", text: $viewModel.renameFileNameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 244)
                Text(".html")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { viewModel.commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedTitle.isEmpty || trimmedFileName.isEmpty)
            }
        }
        .padding(16)
    }
}
