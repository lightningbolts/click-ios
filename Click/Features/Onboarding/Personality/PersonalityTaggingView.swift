import SwiftUI

/// Phase 2 Personality tagging screen with 4 affinity groups and exactly 5 traits required.
public struct PersonalityTaggingView: View {
    @State private var selectedTraits: Set<String>
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    let title: String
    let subtitle: String
    let actionTitle: String
    let onSave: ([String]) async throws -> Void

    /// Settings reuses this picker with its own copy; onboarding keeps the defaults.
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
        VStack(spacing: 0) {
            OnboardingHeaderView(title: title, subtitle: subtitle)

            // Counter indicator
            HStack(spacing: ClickSpacing.xs) {
                Text("\(selectedTraits.count) of \(kPersonalityRequiredTagCount) selected")
                    .font(ClickTypography.supportingEmphasized)
                    .fontWeight(.semibold)

                if selectedTraits.count == kPersonalityRequiredTagCount {
                    Text("✓")
                        .font(ClickTypography.supportingEmphasized)
                        .fontWeight(.bold)
                        .foregroundStyle(ClickColors.accentForeground)
                }
                Spacer()
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.bottom, ClickSpacing.sm)
            .foregroundStyle(selectedTraits.count == kPersonalityRequiredTagCount ? ClickColors.accentForeground : ClickColors.textPrimary)

            if let error = errorMessage {
                Text(error)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.destructive)
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.bottom, ClickSpacing.xs)
            }

            // Trait Groups Scroll
            ScrollView {
                VStack(alignment: .leading, spacing: ClickSpacing.lg) {
                    ForEach(kPersonalityTraitGroups) { group in
                        VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                            Text(group.title.uppercased())
                                .font(ClickTypography.metadata)
                                .fontWeight(.bold)
                                .foregroundStyle(ClickColors.textSecondary)

                            FlowLayout(spacing: ClickSpacing.sm) {
                                ForEach(group.traits, id: \.self) { trait in
                                    let isSelected = selectedTraits.contains(trait)
                                    Button(action: {
                                        toggleTrait(trait)
                                    }) {
                                        HStack(spacing: ClickSpacing.xxs) {
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .bold))
                                            }
                                            Text(trait)
                                                .font(ClickTypography.body)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(isSelected ? ClickColors.selectionTint : ClickColors.surface)
                                        .foregroundStyle(isSelected ? ClickColors.accentForeground : ClickColors.textPrimary)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(isSelected ? ClickColors.accentForeground : ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, ClickSpacing.lg)
                .padding(.vertical, ClickSpacing.sm)
                .padding(.bottom, 80)
            }

            // Bottom Sticky Bar
            VStack(spacing: 0) {
                Divider()
                    .overlay(ClickColors.separator)

                Button(action: {
                    saveAndContinue()
                }) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.clickPrimary)
                .disabled(!canContinue)
                .padding(.horizontal, ClickSpacing.lg)
                .padding(.vertical, ClickSpacing.md)
                .background(ClickColors.background)
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
    }

    private func toggleTrait(_ trait: String) {
        if selectedTraits.contains(trait) {
            ClickHaptics.selection()
            selectedTraits.remove(trait)
        } else if selectedTraits.count < kPersonalityRequiredTagCount {
            ClickHaptics.selection()
            selectedTraits.insert(trait)
        } else {
            ClickHaptics.error()
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

