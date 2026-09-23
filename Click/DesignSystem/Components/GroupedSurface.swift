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
