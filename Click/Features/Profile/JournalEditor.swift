import SwiftUI

/// Focused journal note editor (spec §47.2). Saves only when the server confirms; a failure
/// keeps the text and says so.
struct JournalEditor: View {
    let target: JournalEditorTarget
    let onSave: (String, JournalEntry.Visibility) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var visibility: JournalEntry.Visibility
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private static let maxLength = 1200

    init(target: JournalEditorTarget, onSave: @escaping (String, JournalEntry.Visibility) async throws -> Void) {
        self.target = target
        self.onSave = onSave
        _text = State(initialValue: target.entry?.body ?? "")
        _visibility = State(initialValue: target.entry?.visibility ?? .private)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A memory, a note, a plan…", text: $text, axis: .vertical)
                        .lineLimit(6...14)
                        .focused($isFocused)
                        .onChange(of: text) { _, value in
                            if value.count > Self.maxLength { text = String(value.prefix(Self.maxLength)) }
                        }
                } footer: {
                    Text("\(text.count)/\(Self.maxLength)")
                }
                Section {
                    Picker("Visible to", selection: $visibility) {
                        ForEach(JournalEntry.Visibility.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                } footer: {
                    Text(visibility == .private ? "Only you can see this note." : "This person can see this note on your shared timeline.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(ClickColors.destructive) }
                }
            }
            .navigationTitle(target.entry == nil ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await onSave(text.trimmingCharacters(in: .whitespacesAndNewlines), visibility)
            ClickHaptics.success()
            dismiss()
        } catch {
            errorMessage = "Your note wasn't saved. \(error.userFacingMessage)"
        }
    }
}
