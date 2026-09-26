import SwiftUI

extension View {
    /// Places content in a neutral grouped region: `surface` fill with the grouped-surface
    /// radius. Boundaries come from background contrast, so no outline is drawn; use hairline
    /// dividers between rows inside the region. This is visual grouping only — it carries no
    /// information semantics and should not wrap every piece of metadata.
    public func groupedSurface() -> some View {
        background(
            ClickColors.surface,
            in: RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
    }
}

/// A titled grouped card for scrolling pages (the look of an inset-grouped list, laid out
/// eagerly so the page's height is known up front): each child becomes a full-width row with
/// an inset divider after it. Buttons are full-width rows, tinted (red when destructive).
struct GroupedSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.textSecondary)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            Group(subviews: content) { rows in
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { index in
                            rows[index]
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            if index < rows.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .buttonStyle(GroupedRowButtonStyle())
                    .labelStyle(GroupedRowLabelStyle())
                    .groupedSurface()
                }
            }
        }
    }
}

/// A grouped-card row button: the whole row is the target, with a pressed highlight.
private struct GroupedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? ClickColors.destructive : ClickColors.accentForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if configuration.isPressed {
                    ClickColors.fillSubtle.padding(.horizontal, -16).padding(.vertical, -10)
                }
            }
    }
}

/// Row labels with their icons in one column, so titles line up whatever the symbol's width.
private struct GroupedRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 28)
            configuration.title
        }
    }
}
