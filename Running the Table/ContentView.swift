import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: TableViewModel
    // Custom toggle instead of the system one: SwiftUI parks the system toggle
    // behind a flexible space, so it slides on every collapse.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, sidebar: {
            SidebarView(viewModel: viewModel)
                // A sidebar navigationTitle makes the system re-insert its toggle.
                // 132 puts the divider flush against the toggle pill (ends 131.5).
                .navigationSplitViewColumnWidth(132)
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            withAnimation {
                                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .keyboardShortcut("s", modifiers: [.control, .command])
                        .help("Show or hide the sidebar (Ctrl+Cmd+S)")
                        .accessibilityLabel("Toggle Sidebar")
                    }
                }
        }, detail: {
            if viewModel.selectedDocumentID != nil {
                EditorView(viewModel: viewModel)
                    .navigationTitle(viewModel.table.name)
            } else {
                emptyState
            }
        })
        // New-table lives in EditorView's trailing toolbar: the leading region
        // reserves a 53pt toggle slot that shifts when the sidebar collapses.
        // Opaque toolbar surface so sidebar material doesn't reach the title bar.
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 600)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Table Selected", systemImage: "tablecells")
        } description: {
            Text("Create a table to get started.")
        } actions: {
            Button("New Table") {
                viewModel.newTable()
            }
            .buttonStyle(.borderedProminent)
            .help("New table (Cmd+N)")
        }
        .navigationTitle("Running the Table")
    }
}

// Rows stay plain text until renamed so the list — not a text field — holds
// focus, which is what makes the Delete key work.
struct SidebarView: View {
    @ObservedObject var viewModel: TableViewModel
    @State private var editingID: UUID?
    @State private var swipedID: UUID?

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedDocumentID },
            set: { if let id = $0 { viewModel.selectDocument(id) } }
        )) {
            ForEach(viewModel.documents) { document in
                SidebarRow(viewModel: viewModel,
                           documentID: document.id,
                           isEditing: editingID == document.id,
                           beginEdit: { editingID = document.id },
                           endEdit: {
                               if editingID == document.id { editingID = nil }
                           })
                    .tag(document.id)
                    .opacity(swipedID == document.id ? 0.55 : 1)
                    // Icon-only: a titled action is wider than the compact
                    // sidebar can reveal, and SwiftUI then suppresses it entirely.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.deleteDocument(document.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete")
                    } onPresentationChanged: { isRevealed in
                        swipedID = isRevealed ? document.id : nil
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            viewModel.deleteDocument(document.id)
                        }
                    }
            }
            .onDelete { offsets in
                viewModel.deleteDocument(at: offsets)
            }
        }
        .listStyle(.sidebar)
        // Works only while the list itself has focus (not mid-rename).
        .onKeyPress(.delete) {
            guard let id = viewModel.selectedDocumentID else { return .ignored }
            viewModel.deleteDocument(id)
            return .handled
        }
    }
}

struct SidebarRow: View {
    @ObservedObject var viewModel: TableViewModel
    let documentID: UUID
    let isEditing: Bool
    let beginEdit: () -> Void
    let endEdit: () -> Void

    @FocusState private var nameFieldFocused: Bool

    private var nameBinding: Binding<String> {
        Binding(
            get: { viewModel.document(id: documentID)?.name ?? "" },
            set: { viewModel.renameDocument(documentID, to: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isEditing {
                TextField("Table name", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($nameFieldFocused)
                    .onSubmit(endEdit)
                    .onExitCommand(perform: endEdit)
            } else {
                Text(viewModel.document(id: documentID)?.name ?? "")
                    .font(.body.weight(.medium))
                    // No contentShape(): a full-row hit target steals the swipe.
                    .onTapGesture(count: 2) { beginEdit() }
            }
            Text(viewModel.document(id: documentID)?.fileURL?.lastPathComponent ?? "Not saved yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onChange(of: isEditing) { _, editing in
            if editing {
                nameFieldFocused = true
            }
        }
        .onChange(of: nameFieldFocused) { _, focused in
            if !focused { endEdit() }
        }
    }
}

#Preview {
    ContentView(viewModel: TableViewModel())
}
