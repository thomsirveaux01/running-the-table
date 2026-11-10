import SwiftUI

// Groups must go through .toolbar (not a body HStack), each in a
// ToolbarItemGroup, or placements clash.
struct EditorView: View {
    @ObservedObject var viewModel: TableViewModel

    // One font definition so every drawn toolbar label matches.
    private static let monoNSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    // macOS merges toolbar items into one pill only for image-like content;
    // a Text label claims its own platter — so labels are drawn as images.
    private static func labelImage(_ text: String, width: CGFloat = 24) -> some View {
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: monoNSFont,
                .foregroundColor: NSColor.black,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2,
                                  y: (rect.height - size.height) / 2),
                      withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return Image(nsImage: image)
            .accessibilityLabel(text)
    }

    var body: some View {
        VSplitView {
            WYSIWYGView(viewModel: viewModel)
                .frame(minHeight: 200, maxHeight: .infinity)
            HTMLView(viewModel: viewModel)
                .frame(minHeight: 140, idealHeight: 260, maxHeight: .infinity)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $viewModel.showLinkPrompt) { linkSheet }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The leading region reserves a 53pt toggle slot that shifts when the
        // sidebar collapses; the trailing region holds one x in both states.
        // Same button face in both states; it only gains the pull-down once a
        // template exists, so a fresh install keeps a plain one-click New.
        ToolbarItem(placement: .automatic) {
            if viewModel.templates.isEmpty {
                Button {
                    viewModel.newTable()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .keyboardShortcut("n")
                .help("New table (Cmd+N)")
                .accessibilityLabel("New Table")
            } else {
                Menu {
                    Button("Blank Table") { viewModel.newTable() }
                        .keyboardShortcut("n")
                    Divider()
                    ForEach(viewModel.sortedTemplates) { template in
                        Button(template.name) { viewModel.newTable(fromTemplate: template) }
                    }
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("New table from blank or template")
                .accessibilityLabel("New Table")
            }
        }

        // Explicit spacer: without it the item merges into the next pill.
        ToolbarSpacer(.fixed, placement: .automatic)

        // Toggles light up when the focused cell carries the attribute; their
        // chords live in the menus, which can print them.
        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: viewModel.boldBinding) {
                Image(systemName: "bold")
            }
            .toggleStyle(.button)
            .help("Bold (Cmd+B)")
            .accessibilityLabel("Bold")

            Toggle(isOn: viewModel.italicBinding) {
                Image(systemName: "italic")
            }
            .toggleStyle(.button)
            .help("Italic (Cmd+I)")
            .accessibilityLabel("Italic")

            Button { viewModel.beginLinkEntry() } label: {
                Image(systemName: "link")
            }
            .help("Insert link (Cmd+K)")
            .accessibilityLabel("Insert Link")

            Toggle(isOn: viewModel.headerBinding) {
                Self.labelImage("th")
            }
            .toggleStyle(.button)
            .help("Toggle header cell (Cmd+Shift+H)")
        }

        ToolbarSpacer(.fixed, placement: .automatic)

        // Labels name the HTML tags they act on.
        ToolbarItemGroup(placement: .automatic) {
            Button { viewModel.addRow() } label: {
                Self.labelImage("tr+")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help("Add row below (Cmd+Option+R)")

            Button { viewModel.removeRow() } label: {
                Self.labelImage("tr-")
            }
            .help("Remove focused row (Cmd+Option+Shift+R)")

            Button { viewModel.addColumn() } label: {
                Self.labelImage("td+")
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .help("Add column to the right (Cmd+Option+C)")

            Button { viewModel.removeColumn() } label: {
                Self.labelImage("td-")
            }
            .help("Remove focused column (Cmd+Option+Shift+C)")
        }

        // A Menu, not a Picker: shows the word "colspan" instead of the
        // selected value (the chevron comes free).
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                ForEach(TableCell.minColspan...TableCell.maxColspan, id: \.self) { span in
                    Button {
                        viewModel.colspanBinding.wrappedValue = span
                    } label: {
                        if viewModel.colspanBinding.wrappedValue == span {
                            Label("\(span)", systemImage: "checkmark")
                        } else {
                            Text("\(span)")
                        }
                    }
                }
            } label: {
                Self.labelImage("colspan", width: 56)
            }
            .help("Column span of the focused cell (1-6)")
        }
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Link")
                .font(.headline)
            TextField("https://example.com", text: $viewModel.linkURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.showLinkPrompt = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { viewModel.applyLink() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
