import SwiftUI

/// Suggested + all context tags, multi-select, with a custom label (≤25). Shared by the
/// post-connect screen and "Edit tags" on a timeline encounter.
struct ContextTagPicker: View {
    @Binding var selected: [String]
    @Binding var custom: String
    let suggestions: [ContextTag]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !suggestions.isEmpty {
                Text("Suggested")
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.textSecondary)
                FlowLayout(spacing: 8) {
                    ForEach(suggestions) { tag in
                        chip("\(tag.emoji) \(tag.label)", id: tag.id)
                    }
                }
            }

            Text("All tags")
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.textSecondary)
            FlowLayout(spacing: 8) {
                ForEach(ContextTagTaxonomy.all) { tag in
                    chip("\(tag.emoji) \(tag.label)", id: tag.id)
                }
                ForEach(selected.filter { id in !ContextTagTaxonomy.all.contains { $0.id == id } }, id: \.self) { id in
                    chip(ContextTagTaxonomy.label(for: id), id: id)
                }
            }

            Text("Custom activity")
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.textSecondary)
            TextField("Something else (\(ContextTagTaxonomy.maxCustomLength) characters)", text: $custom)
                .textInputAutocapitalization(.sentences)
                .onChange(of: custom) { _, value in
                    if value.count > ContextTagTaxonomy.maxCustomLength {
                        custom = String(value.prefix(ContextTagTaxonomy.maxCustomLength))
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Selected tags plus the trimmed custom label, deduplicated.
    static func resolved(selected: [String], custom: String) -> [String] {
        var tags = selected
        let label = String(custom.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContextTagTaxonomy.maxCustomLength))
        if !label.isEmpty, !tags.contains(label) { tags.append(label) }
        return tags
    }

    private func chip(_ title: String, id: String) -> some View {
        let isOn = selected.contains(id)
        return Button {
            ClickHaptics.selection()
            if let index = selected.firstIndex(of: id) { selected.remove(at: index) } else { selected.append(id) }
        } label: {
            Text(title)
                .font(ClickTypography.supporting.weight(isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? ClickColors.accentForeground : ClickColors.textSecondary)
                .padding(.horizontal, 14)
                .frame(minHeight: ClickMetrics.chipHeight)
                .background(isOn ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
