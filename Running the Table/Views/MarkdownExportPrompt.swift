import SwiftUI

/// A sheet, not an alert, so long loss lists scroll.
struct MarkdownExportPrompt: View {
    var viewModel: TableViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.markdownExportBlocked {
                Text("Markdown tables require a header row. Add one, then export again.")
                    .font(.headline)
            } else {
                // fixedSize: the greedy loss ScrollView otherwise wins the
                // sheet's height budget and squeezes this to one truncated line.
                Text("Markdown doesn't support all formatting in this table. It will export with these changes:")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.markdownExportLosses, id: \.self) { loss in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(loss)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelMarkdownExport() }
                    .keyboardShortcut(.cancelAction)
                if !viewModel.markdownExportBlocked {
                    Button("Export Anyway") { viewModel.confirmMarkdownExport() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
