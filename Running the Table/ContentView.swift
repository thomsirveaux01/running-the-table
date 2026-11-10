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
                // Notes' sidebar measures 201pt over AX; 200 is the round
                // default. Must trail the .toolbar modifiers (see facts).
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 320)
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
        // Root-level sheets: the save prompt opens from the sidebar menu too,
        // where EditorView may not be on screen.
        .sheet(isPresented: $viewModel.showTemplatePrompt) {
            TemplateNamePrompt(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showTemplateManager) {
            TemplateManagerView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showRenamePrompt) {
            RenameTablePrompt(viewModel: viewModel)
        }
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

    // Notes-style rule. listRowBackground is sized to the whole row, so it lands
    // on the row boundary; an overlay on the row content stops ~4pt short.
    @ViewBuilder
    private func separationRule(after document: TableDocument) -> some View {
        Color.clear.overlay(alignment: .bottom) {
            if showsRule(after: document) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    // 10pt matches the selection pill's inset (it spans 10-122).
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    // The pill fills the row, so a rule touching it — either under it or against
    // its top edge — reads as a stray hairline across the highlight.
    private func showsRule(after document: TableDocument) -> Bool {
        guard let idx = viewModel.documents.firstIndex(where: { $0.id == document.id }),
              idx + 1 < viewModel.documents.count else { return false }
        return viewModel.selectedDocumentID != document.id
            && viewModel.selectedDocumentID != viewModel.documents[idx + 1].id
    }

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
                        Button("Rename…") {
                            viewModel.beginRename(document.id)
                        }
                        Button("Save as Template…") {
                            viewModel.beginTemplateSave(from: document.id)
                        }
                        Button("Duplicate") {
                            viewModel.duplicateDocument(document.id)
                        }
                        Button("Delete", role: .destructive) {
                            viewModel.deleteDocument(document.id)
                        }
                    }
                    .listRowBackground(separationRule(after: document))
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
