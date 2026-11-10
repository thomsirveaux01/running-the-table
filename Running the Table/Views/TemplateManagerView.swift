import SwiftUI

/// Name prompt for "Save as Template…", mirroring the link sheet's shape.
struct TemplateNamePrompt: View {
    @ObservedObject var viewModel: TableViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Template")
                .font(.headline)
            TextField("Template name", text: $viewModel.templateNameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.showTemplatePrompt = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { viewModel.saveAsTemplate() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.templateNameText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

/// Edit ▸ Manage Templates…: rename in place, delete with the trash button.
struct TemplateManagerView: View {
    @ObservedObject var viewModel: TableViewModel
    // Edits stage here and commit on submit, so a half-typed name never
    // touches the template files.
    @State private var drafts: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Templates")
                .font(.headline)

            if viewModel.templates.isEmpty {
                Text("No templates yet. Save one from File ▸ Save as Template…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(viewModel.sortedTemplates) { template in
                    HStack {
                        TextField("Template name", text: draftBinding(for: template))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { commit(template) }
                        Button {
                            viewModel.deleteTemplate(template.id)
                            drafts.removeValue(forKey: template.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete \(template.name)")
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { viewModel.showTemplateManager = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func draftBinding(for template: TableDocument) -> Binding<String> {
        Binding(
            get: { drafts[template.id] ?? template.name },
            set: { drafts[template.id] = $0 }
        )
    }

    private func commit(_ template: TableDocument) {
        guard let draft = drafts[template.id] else { return }
        viewModel.renameTemplate(template.id, to: draft)
        drafts.removeValue(forKey: template.id)
    }
}
