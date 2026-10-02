import SwiftUI

extension EnergyLabel {
    /// Pin ring and pill color (spec §6.5).
    var color: Color {
        switch self {
        case .chill: .blue
        case .steady: .green
        case .lively: .orange
        case .packed: .purple
        }
    }
}

/// A Click Place on the map (§6.5): a rounded square with the category symbol or photo, an energy
/// ring only while the Pulse is live, and a LIVE / start-time badge for official events today.
struct PlacePinView: View {
    let place: PlaceSummary

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ClickColors.surface)
                .frame(width: 34, height: 34)
                .overlay {
                    if let photo = place.photoURL {
                        AsyncImage(url: photo) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            symbol
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        symbol
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ClickColors.separator, lineWidth: 1.5))
                .overlay {
                    if place.pulse.state == .live, let label = place.pulse.label {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(label.color, lineWidth: 3)
                            .frame(width: 40, height: 40)
                    }
                }
            if let badge = PlaceCopy.pinBadge(place) {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(badge == "LIVE" ? Color.red : ClickColors.primaryActionFill, in: Capsule())
                    .offset(x: 10, y: -8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: some View {
        Image(systemName: place.category.symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ClickColors.textPrimary)
    }

    private var accessibilityText: String {
        var parts = [place.name, place.category.label]
        if place.pulse.state == .live, let label = place.pulse.label { parts.append("\(label.title) now") }
        if let badge = PlaceCopy.pinBadge(place) { parts.append(badge == "LIVE" ? "event live now" : "event at \(badge)") }
        return parts.joined(separator: ", ")
    }
}
