import SwiftUI

/// Home's one past-event surface (spec F2): a recap card for an event you were at in the last
/// ~48 hours, linking to its Click Drops recap. It disappears on its own; older events stay in
/// Past events.
struct HomeEventRecapCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var card: PastEvent?

    var body: some View {
        Group {
            if let card {
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
        }
        .task { card = try? await env.beacons.eventRecapCard() }
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
    @Environment(AppEnvironment.self) private var env
    let userID: String
    @State private var events: [PastEvent] = []

    var body: some View {
        Group {
            if !events.isEmpty {
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
        .task(id: userID) { events = (try? await env.beacons.eventsTogether(userID: userID)) ?? [] }
    }
}
