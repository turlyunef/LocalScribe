import SwiftUI
import LocalScribeCore

struct GroupNameDraft: Identifiable {
    let id = UUID()
    let groupID: String?
    let name: String
}

/// Inline single-field section name editor. Placeholder and accessibility
/// identifiers are caller-defined; the defaults keep the recording behaviour.
struct GroupNameEditor: View {
    let draft: GroupNameDraft
    let placeholder: String
    let fieldIdentifier: String
    let errorIdentifier: String
    let save: (String) async throws -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var error: String?
    @State private var saving = false
    @State private var finished = false
    @FocusState private var focused: Bool
    init(draft: GroupNameDraft,
         placeholder: String = L10n.text("Название группы"),
         fieldIdentifier: String = "groups.name",
         errorIdentifier: String = "groups.name.error",
         save: @escaping (String) async throws -> Void,
         cancel: @escaping () -> Void) {
        self.draft = draft
        self.placeholder = placeholder
        self.fieldIdentifier = fieldIdentifier
        self.errorIdentifier = errorIdentifier
        self.save = save; self.cancel = cancel
        _name = State(initialValue: draft.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier(fieldIdentifier)
                .onSubmit { commit(blur: false) }
                .onExitCommand { guard !saving else { return }; finished = true; cancel() }
                .onChange(of: focused) { _, value in if !value { commit(blur: true) } }
                .disabled(saving)
            if let error { Text(L10n.message(error)).font(.caption).foregroundStyle(.red).accessibilityIdentifier(errorIdentifier) }
        }.padding(8)
            .task { await Task.yield(); focused = true }
    }
    private func commit(blur: Bool) {
        guard !finished, !saving else { return }
        if blur && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finished = true; cancel(); return
        }
        saving = true
        Task {
            do { try await save(name); finished = true }
            catch { self.error = error.localizedDescription; saving = false; focused = true }
            saving = false
        }
    }
}
