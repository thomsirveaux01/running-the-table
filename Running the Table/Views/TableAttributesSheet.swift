import SwiftUI

/// Sheet for the table tag's own attributes: border, cellpadding, style,
/// anything the author cares to write. Rows edit name/value pairs; the grid
/// never touches these, it only keeps them.
struct TableAttributesSheet: View {
    @ObservedObject var viewModel: TableViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Table Attributes")
                .font(.headline)
            Text("Written verbatim into the <table> tag.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.attributesDraft.isEmpty {
                Text("No attributes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.attributesDraft.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("name", text: $viewModel.attributesDraft[index].name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        TextField("value", text: $viewModel.attributesDraft[index].value)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 194)
                        Button {
                            viewModel.removeAttributeRow(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this attribute")
                    }
                }
            }

            Button("Add Attribute") { viewModel.addAttributeRow() }

            Divider()

            Text("Accessibility")
                .font(.headline)
            Toggle("Add scope to header cells", isOn: $viewModel.accessibilityScope)
                .help("Emit scope=\"col\" on head rows, scope=\"row\" on other <th> cells")
            Toggle("Add screen-reader text to empty merged cells",
                   isOn: $viewModel.accessibilitySRText)
                .help("Emit aria-label on empty cells that span columns or rows")

            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelTableAttributes() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { viewModel.commitTableAttributes() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
