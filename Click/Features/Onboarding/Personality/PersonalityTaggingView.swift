import SwiftUI

/// Personality picker (Settings, and Home's setup prompt): exactly 5 traits from 4 groups.
public struct PersonalityTaggingView: View {
    @State private var selectedTraits: Set<String>
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var showsSwapHint = false

    let title: String
    let subtitle: String
    let actionTitle: String
    let onSave: ([String]) async throws -> Void

    public init(
        initialTraits: [String] = [],
        title: String = "How would friends describe you?",
        subtitle: String = "Pick exactly 5 traits that capture how you show up in the world.",
        actionTitle: String = "Continue",
        onSave: @escaping ([String]) async throws -> Void
    ) {
        self._selectedTraits = State(initialValue: Set(canonicalizePersonalityTags(initialTraits)))
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.onSave = onSave
    }

    private var canContinue: Bool {
        selectedTraits.count == kPersonalityRequiredTagCount && !isSaving
    }

    public var body: some View {
        OnboardingPage(title: title, subtitle: subtitle) {
            ForEach(kPersonalityTraitGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title)
                        .font(ClickTypography.supportingEmphasized)
                        .foregroundStyle(ClickColors.textSecondary)
                        .padding(.horizontal, 4)
                        .accessibilityAddTraits(.isHeader)
                    FlowLayout(spacing: ClickSpacing.sm) {
                        ForEach(group.traits, id: \.self) { trait in
                            SelectableChip(title: trait, isSelected: selectedTraits.contains(trait)) { toggleTrait(trait) }
                        }
                    }
                }
            }
        } actions: {
            if let errorMessage {
                FormNotice(text: errorMessage)
            } else if showsSwapHint, selectedTraits.count == kPersonalityRequiredTagCount {
                // A 6th tap used to only buzz; say how to change a pick.
                Text("That's 5. Tap one to swap it out.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textSecondary)
                    .transition(.opacity)
            }
            Button(action: saveAndContinue) {
                if isSaving {
                    ProgressView()
                } else if selectedTraits.count < kPersonalityRequiredTagCount {
                    Text("Pick \(kPersonalityRequiredTagCount - selectedTraits.count) more")
                } else {
                    Text(actionTitle)
                }
            }
            .buttonStyle(.clickPrimary)
            .disabled(!canContinue)
        }
        .animation(ClickMotion.subtleFade, value: showsSwapHint)
    }

    private func toggleTrait(_ trait: String) {
        if selectedTraits.contains(trait) {
            ClickHaptics.selection()
            selectedTraits.remove(trait)
            showsSwapHint = false
        } else if selectedTraits.count < kPersonalityRequiredTagCount {
            ClickHaptics.selection()
            selectedTraits.insert(trait)
        } else {
            ClickHaptics.error()
            showsSwapHint = true
        }
    }

    private func saveAndContinue() {
        guard canContinue else { return }
        ClickHaptics.impact(.medium)
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await onSave(Array(selectedTraits))
                ClickHaptics.success()
            } catch {
                errorMessage = "Couldn't save personality traits. Check your connection."
                ClickHaptics.error()
            }
            isSaving = false
        }
    }
}

