import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: TableViewModel
    // Defaulted so the offscreen probes keep compiling without owning one.
    @ObservedObject var updater: UpdateChecker = UpdateChecker()
    @ObservedObject var library: LibraryCoordinator = LibraryCoordinator()
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
                // Must trail the .toolbar modifiers (see facts).
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
        .sheet(isPresented: $viewModel.showTableAttributes) {
            TableAttributesSheet(viewModel: viewModel)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task { await updater.check(userInitiated: false) }
        .alert(alertTitle, isPresented: statusShown, actions: { alertButtons }, message: {
            Text(alertMessage)
        })
        .sheet(isPresented: updateShown) {
            if case let .available(version, notes) = updater.prompt {
                UpdatePromptView(version: version, notes: notes,
                                 onDownload: { Task { await updater.downloadPromptedUpdate() } },
                                 onSkip: { updater.skipPromptedVersion() },
                                 onLater: { updater.prompt = nil })
            }
        }
        .alert("Lost Access to Your Tables", isPresented: lostAccessShown) {
            Button("Choose Folder…") { library.regrantAfterLoss() }
            Button("Use Container", role: .cancel) { library.useContainerFallback() }
        } message: {
            Text("The app can no longer reach \(lostPath). Re-select it to keep your tables there, or fall back to the app's container.")
        }
        .sheet(isPresented: $library.showSettings) {
            LibrarySettingsView(library: library)
        }
        .sheet(isPresented: moveShown) {
            libraryChoiceSheet(title: "Move Your Tables?",
                               body: "Move \(moveCount) table(s) from \(moveFrom.path) to \(moveTo.path)? Copy keeps the originals in place.",
                               confirm: "Move",
                               onConfirm: { library.resolveMove(copy: false) },
                               onCancel: { library.cancelMove() },
                               extra: ("Copy", { library.resolveMove(copy: true) }))
        }
        .alert("Couldn't Finish", isPresented: failureShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.failure ?? "")
        }
    }

    // MARK: - Library prompts

    private var lostAccessShown: Binding<Bool> {
        Binding(get: { if case .lostAccess = library.step { return true }; return false },
                set: { if !$0 { library.step = .none } })
    }
    private var lostPath: String {
        if case let .lostAccess(path) = library.step { return path }
        return ""
    }

    private var moveShown: Binding<Bool> {
        Binding(get: { if case .moveOffer = library.step { return true }; return false }, set: { _ in })
    }
    private var moveCount: Int {
        if case let .moveOffer(count, _, _) = library.step { return count }; return 0
    }
    private var moveFrom: URL {
        if case let .moveOffer(_, from, _) = library.step { return from }; return LibraryLocation.directory
    }
    private var moveTo: URL {
        if case let .moveOffer(_, _, to) = library.step { return to }; return LibraryLocation.directory
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { library.failure != nil }, set: { if !$0 { library.failure = nil } })
    }

    @ViewBuilder
    private func libraryChoiceSheet(title: String, body text: String, confirm: String,
                                    onConfirm: @escaping () -> Void,
                                    onCancel: @escaping () -> Void,
                                    extra: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                if let extra {
                    Button(extra.0, action: extra.1)
                }
                Button(confirm) { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Update prompt

    // The two status popups ride the stock alert; the available-prompt is a
    // sheet because alerts cannot scroll long release notes.
    private var statusShown: Binding<Bool> {
        Binding(get: {
            if case .available = updater.prompt { return false }
            return updater.prompt != nil
        }, set: { if !$0 { updater.prompt = nil } })
    }

    private var updateShown: Binding<Bool> {
        Binding(get: {
            if case .available = updater.prompt { return true }
            return false
        }, set: { if !$0 { updater.prompt = nil } })
    }

    private var alertTitle: String {
        switch updater.prompt {
        case .available: ""
        case .upToDate: "You’re Up to Date"
        case .checkFailed: "Update Check Failed"
        case nil: ""
        }
    }

    private var alertMessage: String {
        switch updater.prompt {
        case .available:
            return ""
        case .upToDate:
            return "Version \(updater.currentVersion) is the latest release."
        case .checkFailed:
            // Vague on purpose: covers dead networks, rate limits, and a 404
            // (no release published yet) alike.
            return "Couldn't check for updates. Try again later."
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private var alertButtons: some View {
        Button("OK", role: .cancel) {}
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

    // listRowBackground is sized to the whole row, so it lands on the row
    // boundary; an overlay on the row content stops ~4pt short.
    @ViewBuilder
    private func separationRule(after document: TableDocument) -> some View {
        Color.clear.overlay(alignment: .bottom) {
            if showsRule(after: document) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    // 10pt matches the selection pill's inset.
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
            get: { viewModel.sidebarSelection },
            set: { newValue in
                // SwiftUI hands the List's selection change to this setter during
                // its own view-update pass; applySidebarSelection loads a document,
                // which would publish mid-update. Defer to the next main-actor turn.
                Task { @MainActor in viewModel.applySidebarSelection(newValue) }
            }
        )) {
            ForEach(viewModel.documents) { document in
                SidebarRow(viewModel: viewModel,
                           documentID: document.id,
                           isEditing: editingID == document.id,
                           beginEdit: { editingID = document.id },
                           endEdit: {
                               guard editingID == document.id else { return }
                               editingID = nil
                               // The name changed on each keystroke; now move
                               // the file to match it.
                               viewModel.commitInlineRename(document.id)
                           })
                    .tag(document.id)
                    .opacity(swipedID == document.id ? 0.55 : 1)
                    .modifier(SwipeToDelete(
                        onDelete: { viewModel.deleteDocument(document.id) },
                        onRevealedChange: { swipedID = $0 ? document.id : nil }))
                    .contextMenu {
                        // Finder-style: the row is in a ⌘-selection, so the
                        // bulk commands take the whole set.
                        let targetIDs = viewModel.sidebarSelection.contains(document.id)
                            ? viewModel.sidebarSelection
                            : [document.id]
                        if viewModel.selectedDocumentIDs.count == 1 {
                            Button("Rename…") {
                                viewModel.beginRename(document.id)
                            }
                            Button("Save as Template…") {
                                viewModel.beginTemplateSave(from: document.id)
                            }
                        }
                        Button("Duplicate") {
                            viewModel.duplicateDocuments(targetIDs)
                        }
                        Button("Delete", role: .destructive) {
                            viewModel.deleteDocuments(targetIDs)
                        }
                    }
                    .listRowBackground(separationRule(after: document))
            }
            .onDelete { offsets in
                viewModel.deleteDocument(at: offsets)
            }
        }
        .listStyle(.sidebar)
        // Works only while the list itself has focus (not mid-rename); the
        // whole ⌘-selection goes.
        .onKeyPress(.delete) {
            guard viewModel.selectedDocumentID != nil else { return .ignored }
            viewModel.deleteSelectedDocument()
            return .handled
        }
    }
}

// Swipe-to-delete. Dim-while-revealed needs the onPresentationChanged
// overload (macOS 27+); older targets get the action without the dim.
private struct SwipeToDelete: ViewModifier {
    let onDelete: () -> Void
    let onRevealedChange: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteButton
            } onPresentationChanged: { isRevealed in
                onRevealedChange(isRevealed)
            }
        } else {
            content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteButton
            }
        }
    }

    // Icon-only: a titled action is wider than the compact sidebar can
    // reveal, and SwiftUI then suppresses it entirely.
    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Delete")
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

    // The file's mtime stands in for "last edited": autosave rewrites it on
    // every change and steady-state launches never rewrite unchanged files.
    // Fixed formatter: FormatStyle can't easily produce "MM/dd/yy, hh:mm a".
    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy, hh:mm a"
        return formatter
    }()

    private var modifiedCaption: String {
        guard let url = viewModel.document(id: documentID)?.fileURL,
              let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "Not saved yet" }
        return Self.modifiedFormatter.string(from: mtime)
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
            Text(modifiedCaption)
                .font(.system(size: 11))
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

/// Update-available sheet: one-line announcement, bulleted release notes
/// capped at a scrollable height so a long list cannot break the window,
/// then the actions (Download is the default button).
struct UpdatePromptView: View {
    let version: String
    let notes: String
    var onDownload: () -> Void
    var onSkip: () -> Void
    var onLater: () -> Void

    // GitHub note bodies are markdown bullets; the dialog renders real ones.
    // Internal so updateprompt_probe can pin the parsing.
    var bullets: [String] {
        notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version \(version) is available!")
                .font(.headline)
            if !bullets.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(bullets, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(line)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button("Later", action: onLater)
                    .keyboardShortcut(.cancelAction)
                Button("Skip This Version", action: onSkip)
                Button("Download", action: onDownload)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

#Preview {
    ContentView(viewModel: TableViewModel())
}
