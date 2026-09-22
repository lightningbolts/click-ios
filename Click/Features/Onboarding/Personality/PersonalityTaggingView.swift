import SwiftUI

/// Phase 2 Personality tagging screen with 4 affinity groups and exactly 5 traits required.
public struct PersonalityTaggingView: View {
    @State private var selectedTraits: Set<String>
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    let onSave: ([String]) async throws -> Void

    public init(
        initialTraits: [String] = [],
        onSave: @escaping ([String]) async throws -> Void
    ) {
        self._selectedTraits = State(initialValue: Set(canonicalizePersonalityTags(initialTraits)))
        self.onSave = onSave
    }

    private var canContinue: Bool {
        selectedTraits.count == kPersonalityRequiredTagCount && !isSaving
    }

    public var body: some View {
        VStack(spacing: 0) {
            OnboardingHeaderView(
                title: "How would friends describe you?",
                subtitle: "Pick exactly 5 traits that capture how you show up in the world."
            )

            // Counter indicator
            HStack(spacing: ClickSpacing.xs) {
                Text("\(selectedTraits.count) of \(kPersonalityRequiredTagCount) selected")
                    .font(ClickTypography.titleSmall)
                    .fontWeight(.semibold)

                if selectedTraits.count == kPersonalityRequiredTagCount {
                    Text("✓")
                        .font(ClickTypography.titleSmall)
                        .fontWeight(.bold)
                        .foregroundStyle(ClickColors.primary)
                }
                Spacer()
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.bottom, ClickSpacing.sm)
            .foregroundStyle(selectedTraits.count == kPersonalityRequiredTagCount ? ClickColors.primary : ClickColors.textPrimary)

            if let error = errorMessage {
                Text(error)
                    .font(ClickTypography.labelSmall)
                    .foregroundStyle(ClickColors.error)
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.bottom, ClickSpacing.xs)
            }

            // Trait Groups Scroll
            ScrollView {
                VStack(alignment: .leading, spacing: ClickSpacing.lg) {
                    ForEach(kPersonalityTraitGroups) { group in
                        VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                            Text(group.title.uppercased())
                                .font(ClickTypography.labelSmall)
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
                                                .font(ClickTypography.bodyMedium)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(isSelected ? ClickColors.primary : ClickColors.surfaceContainerLow)
                                        .foregroundStyle(isSelected ? ClickColors.onPrimary : ClickColors.textPrimary)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(isSelected ? ClickColors.primary : ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
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
                    .overlay(ClickColors.quietBorder)

                Button(action: {
                    saveAndContinue()
                }) {
                    HStack(spacing: ClickSpacing.sm) {
                        if isSaving {
                            ProgressView()
                                .tint(ClickColors.onPrimary)
                        } else {
                            Text("Continue")
                                .font(ClickTypography.titleMedium)
                                .fontWeight(.bold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canContinue ? ClickColors.primary : ClickColors.primary.opacity(0.35))
                    .foregroundStyle(ClickColors.onPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                }
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

/// Multi-line flow layout for personality tags.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
