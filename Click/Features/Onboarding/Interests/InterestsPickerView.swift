import SwiftUI

/// Phase 2 Interests selection screen with category accordion and subcategory chips.
public struct InterestsPickerView: View {
    @State private var selectedTags: Set<String>
    @State private var expandedCategories: Set<String>
    @State private var searchQuery: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    let minTags: Int
    let onSave: ([String]) async throws -> Void

    public init(
        initialTags: [String] = [],
        minTags: Int = kInterestOnboardingMinTags,
        initialExpandedCategories: Set<String> = ["Music"],
        onSave: @escaping ([String]) async throws -> Void
    ) {
        self._selectedTags = State(wrappedValue: Set(initialTags))
        self._expandedCategories = State(wrappedValue: initialExpandedCategories)
        self.minTags = minTags
        self.onSave = onSave
    }

    private var canContinue: Bool {
        selectedTags.count >= minTags && !isSaving
    }

    private var filteredCategories: [InterestCategory] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return kInterestCategories }

        return kInterestCategories.compactMap { category in
            let matchesCategory = category.label.lowercased().contains(query)
            let matchingSubs = category.subcategories.filter { $0.lowercased().contains(query) }

            if matchesCategory || !matchingSubs.isEmpty {
                return InterestCategory(
                    emoji: category.emoji,
                    label: category.label,
                    subcategories: matchingSubs.isEmpty ? category.subcategories : matchingSubs
                )
            }
            return nil
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header & Counter
            VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                Text("What are you into?")
                    .font(ClickTypography.headlineLarge)
                    .tracking(-0.5)
                    .foregroundStyle(ClickColors.textPrimary)

                Text("Pick at least \(minTags) interests to help find common ground with your connections.")
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textSecondary)

                // Selection Counter Badge
                HStack(spacing: ClickSpacing.xs) {
                    Text("\(selectedTags.count) selected")
                        .font(ClickTypography.titleSmall)
                        .fontWeight(.semibold)

                    if selectedTags.count < minTags {
                        Text("· need \(minTags - selectedTags.count) more")
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textSecondary)
                    } else {
                        Text("✓")
                            .font(ClickTypography.titleSmall)
                            .fontWeight(.bold)
                            .foregroundStyle(ClickColors.primary)
                    }
                    Spacer()
                }
                .padding(.top, ClickSpacing.xxs)
                .foregroundStyle(selectedTags.count >= minTags ? ClickColors.primary : ClickColors.textPrimary)

                // Search Bar
                HStack(spacing: ClickSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ClickColors.outline)
                    TextField("Search music, sports, tech, food...", text: $searchQuery)
                        .font(ClickTypography.bodyMedium)
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ClickColors.outline)
                        }
                    }
                }
                .padding(.horizontal, ClickSpacing.md)
                .padding(.vertical, 10)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                .overlay(
                    RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                )
                .padding(.top, ClickSpacing.xs)
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.top, ClickSpacing.md)
            .padding(.bottom, ClickSpacing.sm)

            if let error = errorMessage {
                Text(error)
                    .font(ClickTypography.labelSmall)
                    .foregroundStyle(ClickColors.error)
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.bottom, ClickSpacing.xs)
            }

            // Categories List
            ScrollView {
                LazyVStack(spacing: ClickSpacing.sm) {
                    ForEach(filteredCategories) { category in
                        CategoryAccordionRow(
                            category: category,
                            isExpanded: expandedCategories.contains(category.id) || !searchQuery.isEmpty,
                            selectedTags: selectedTags,
                            onToggleCategory: {
                                toggleTag(category.label)
                            },
                            onToggleSubcategory: { sub in
                                toggleTag(sub)
                            },
                            onToggleExpand: {
                                if expandedCategories.contains(category.id) {
                                    expandedCategories.remove(category.id)
                                } else {
                                    expandedCategories.insert(category.id)
                                }
                            }
                        )
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

    private func toggleTag(_ tag: String) {
        ClickHaptics.selection()
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func saveAndContinue() {
        guard canContinue else { return }
        ClickHaptics.impact(.medium)
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await onSave(Array(selectedTags))
                ClickHaptics.success()
            } catch {
                errorMessage = "Couldn't save interests. Check your connection and try again."
                ClickHaptics.error()
            }
            isSaving = false
        }
    }
}

/// An expandable row for an interest category showing selected badges and subcategory chip flow.
private struct CategoryAccordionRow: View {
    let category: InterestCategory
    let isExpanded: Bool
    let selectedTags: Set<String>
    let onToggleCategory: () -> Void
    let onToggleSubcategory: (String) -> Void
    let onToggleExpand: () -> Void

    private var isCategorySelected: Bool {
        selectedTags.contains(category.label)
    }

    private var selectedSubCount: Int {
        category.subcategories.filter { selectedTags.contains($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
            // Category Header Card
            HStack(spacing: ClickSpacing.md) {
                Button(action: onToggleExpand) {
                    HStack(spacing: ClickSpacing.md) {
                        Text(category.emoji)
                            .font(.system(size: 26))

                        VStack(alignment: .leading, spacing: ClickSpacing.xxxSmall) {
                            Text(category.label)
                                .font(ClickTypography.titleSmall)
                                .fontWeight(.semibold)
                                .foregroundStyle(ClickColors.textPrimary)

                            if selectedSubCount > 0 {
                                Text("\(selectedSubCount) sub-interests picked")
                                    .font(ClickTypography.labelSmall)
                                    .foregroundStyle(ClickColors.primary)
                            }
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                // Category Selection Checkbox
                Button(action: onToggleCategory) {
                    Image(systemName: isCategorySelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isCategorySelected ? ClickColors.primary : ClickColors.outline)
                }
                .buttonStyle(.plain)

                // Chevron to Expand/Collapse Subcategories
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClickColors.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, ClickSpacing.md)
            .padding(.vertical, ClickSpacing.sm)
            .background(isCategorySelected ? ClickColors.primaryFixed.opacity(0.3) : ClickColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                    .stroke(isCategorySelected ? ClickColors.primary : ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
            )

            // Subcategory Chips Flow
            if isExpanded {
                SubcategoryChipsFlow(
                    subcategories: category.subcategories,
                    selectedTags: selectedTags,
                    onToggle: onToggleSubcategory
                )
                .padding(.top, ClickSpacing.xxs)
                .padding(.bottom, ClickSpacing.xs)
                .padding(.leading, ClickSpacing.md)
            }
        }
    }
}

/// Flexible chip layout for subcategories.
private struct SubcategoryChipsFlow: View {
    let subcategories: [String]
    let selectedTags: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: ClickSpacing.xs) {
            ForEach(subcategories, id: \.self) { sub in
                let isSelected = selectedTags.contains(sub)
                Button(action: { onToggle(sub) }) {
                    HStack(spacing: ClickSpacing.xxs) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(sub)
                            .font(ClickTypography.labelMedium)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isSelected ? ClickColors.primary : ClickColors.surface)
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

/// Multi-line flow layout implementation in pure SwiftUI.
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
