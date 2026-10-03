import SwiftUI

/// Interests picker (onboarding step 2, and Settings): a grouped list of categories, each opening
/// to selectable chips.
public struct InterestsPickerView: View {
    @State private var selectedTags: Set<String>
    @State private var expandedCategories: Set<String>
    @State private var searchQuery: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    let minTags: Int
    let title: String
    let actionTitle: String
    let onSave: ([String]) async throws -> Void

    /// Settings reuses this picker with its own copy; onboarding keeps the defaults.
    public init(
        initialTags: [String] = [],
        minTags: Int = kInterestOnboardingMinTags,
        initialExpandedCategories: Set<String> = ["Music"],
        title: String = "What are you into?",
        actionTitle: String = "Continue",
        onSave: @escaping ([String]) async throws -> Void
    ) {
        self._selectedTags = State(wrappedValue: Set(initialTags))
        self._expandedCategories = State(wrappedValue: initialExpandedCategories)
        self.minTags = minTags
        self.title = title
        self.actionTitle = actionTitle
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
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        OnboardingPage(
            title: title,
            subtitle: "Pick at least \(minTags). They help you find common ground with the people you meet."
        ) {
            HStack(spacing: ClickSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ClickColors.textTertiary)
                TextField("Search music, sports, food…", text: $searchQuery)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if isSearching {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(ClickTypography.body)
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.searchMinHeight)
            .background(ClickColors.fillSubtle, in: Capsule())

            let categories = filteredCategories
            if categories.isEmpty {
                Text("No interests match \u{201C}\(searchQuery)\u{201D}.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ClickSpacing.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        if index > 0 { HomeDivider(inset: 60) }
                        InterestCategoryRow(
                            category: category,
                            isExpanded: isSearching || expandedCategories.contains(category.id),
                            selectedTags: selectedTags,
                            onToggleTag: toggleTag,
                            onToggleExpand: {
                                withAnimation(ClickMotion.content) {
                                    if expandedCategories.contains(category.id) {
                                        expandedCategories.remove(category.id)
                                    } else {
                                        expandedCategories.insert(category.id)
                                    }
                                }
                            }
                        )
                    }
                }
                .groupedSurface()
            }
        } actions: {
            if let errorMessage { FormNotice(text: errorMessage) }
            Button(action: saveAndContinue) {
                if isSaving {
                    ProgressView()
                } else if selectedTags.count < minTags {
                    // Says what's missing instead of a silently disabled button.
                    Text("Pick \(minTags - selectedTags.count) more")
                } else {
                    Text("\(actionTitle) · \(selectedTags.count) picked")
                }
            }
            .buttonStyle(.clickPrimary)
            .disabled(!canContinue)
        }
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

/// One category in the grouped list: tap to show its chips. The category itself is the first
/// chip, so "Music" and "Live Shows" are picked the same way.
private struct InterestCategoryRow: View {
    let category: InterestCategory
    let isExpanded: Bool
    let selectedTags: Set<String>
    let onToggleTag: (String) -> Void
    let onToggleExpand: () -> Void

    private var pickedCount: Int {
        ([category.label] + category.subcategories).filter(selectedTags.contains).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleExpand) {
                HStack(spacing: 14) {
                    Text(category.emoji)
                        .font(.system(size: 24))
                        .frame(width: 30)
                    Text(category.label)
                        .font(ClickTypography.body)
                        .foregroundStyle(ClickColors.textPrimary)
                    Spacer(minLength: 0)
                    if pickedCount > 0 {
                        Text(pickedCount, format: .number)
                            .font(ClickTypography.badge)
                            .foregroundStyle(ClickColors.primaryActionForeground)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(ClickColors.primaryActionFill, in: Capsule())
                    }
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ClickColors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, ClickSpacing.surfacePadding)
                .frame(minHeight: ClickMetrics.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(pickedCount > 0 ? "\(pickedCount) picked" : "")
            .accessibilityHint(isExpanded ? "Hides choices" : "Shows choices")

            if isExpanded {
                FlowLayout(spacing: ClickSpacing.sm) {
                    ForEach([category.label] + category.subcategories, id: \.self) { tag in
                        SelectableChip(title: tag, isSelected: selectedTags.contains(tag)) { onToggleTag(tag) }
                    }
                }
                .padding(.leading, 60)
                .padding(.trailing, ClickSpacing.surfacePadding)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }
}
