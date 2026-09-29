import SwiftUI

/// Home's one past-event surface (spec F2): a recap card for an event you were at in the last
/// ~48 hours, linking to its Click Drops recap. It disappears on its own; older events stay in
/// Past events.
struct HomeEventRecapCard: View {
    @Environment(AppEnvironment.self) private var env
    let card: PastEvent

    var body: some View {
                Button {
                    env.router.navigate(to: card.recap == nil ? .event(beaconID: card.beaconID) : .eventRecap(beaconID: card.beaconID))
                } label: {
                    HStack(spacing: 14) {
                        EventVisual(seed: card.beaconID, imageURL: card.imageURL, symbol: "sparkles", cornerRadius: 14)
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title)
                                .font(ClickTypography.bodyEmphasized)
                                .foregroundStyle(ClickColors.textPrimary)
                                .lineLimit(1)
                            Text(caption(card))
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(ClickColors.textTertiary)
                    }
                    .padding(14)
                    .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
    }

    private func caption(_ card: PastEvent) -> String {
        switch card.recap {
        case .ready?: "Your recap is ready."
        case .developing(let reveal)?:
            reveal.map { "Everyone's drops develop \($0.formatted(.relative(presentation: .named)))." } ?? "Everyone's drops are developing."
        case nil: "See who was there."
        }
    }
}

/// On a profile: events you and this person both went to — never their full attendance.
struct EventsTogetherSection: View {
    let events: [PastEvent]

    var body: some View {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Events together")
                        .font(ClickTypography.sectionTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(events.prefix(5)) { event in
                        PastEventRow(event: event)
                    }
                }
                .transition(.opacity)
    }
}

/// One past event: when, where, how you took part, and its recap when there is one.
struct PastEventRow: View {
    @Environment(AppEnvironment.self) private var env
    let event: PastEvent

    var body: some View {
        Button {
            env.router.navigate(to: .event(beaconID: event.beaconID))
        } label: {
            HStack(spacing: 12) {
                EventVisual(seed: event.beaconID, imageURL: event.imageURL, symbol: "calendar", cornerRadius: 12)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(ClickTypography.bodyEmphasized).foregroundStyle(ClickColors.textPrimary).lineLimit(1)
                    Text(subtitle).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let recap = event.recap {
                    Button {
                        env.router.navigate(to: .eventRecap(beaconID: event.beaconID))
                    } label: {
                        Label(recap == .ready ? "Recap" : "Developing", systemImage: recap == .ready ? "sparkles" : "hourglass")
                            .font(ClickTypography.metadataEmphasized)
                    }
                    .buttonStyle(.bordered)
                    .tint(ClickColors.accentForeground)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let ends = event.endsAt { parts.append(ends.formatted(date: .abbreviated, time: .omitted)) }
        if let relation = event.relation {
            if relation.hosted { parts.append("Hosted") } else if relation.went { parts.append("Went") }
            else if relation.rsvpd { parts.append("RSVP'd") } else if relation.saved { parts.append("Saved") }
        }
        if let place = event.locationName { parts.append(place) }
        return parts.joined(separator: " · ")
    }
}
