import SwiftUI

/// The event's equal-width labelled icon action (Event chat · Check in · Directions on the event,
/// Calendar · Directions · Contact on the Click Pass). A label, so a button or a menu can wear it.
struct EventActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    var busy = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if busy { ProgressView() } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(height: 24)
            Text(title)
                .font(ClickTypography.supportingEmphasized)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint ?? ClickColors.textPrimary)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 68)
        // Filled tiles; a tinted state (checked in) tints its tile too.
        .background(tint?.opacity(0.16) ?? ClickColors.fillSubtle,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
