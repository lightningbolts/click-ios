import SwiftUI

/// The event's primary action when it sells tickets: it replaces the RSVP button, in its style.
struct TicketButton: View {
    let ticketing: EventTicketing
    let action: () -> Void

    struct State: Equatable {
        let title: String
        let enabled: Bool
    }

    static func state(_ ticketing: EventTicketing) -> State {
        if ticketing.cancelled { return State(title: "Event cancelled", enabled: false) }
        if ticketing.available {
            guard let from = ticketing.fromAmount else { return State(title: "Get tickets", enabled: true) }
            return from == 0
                ? State(title: "Claim free tickets", enabled: true)
                : State(title: "Get tickets · from \(TicketPrice.from(from, currency: ticketing.currency))", enabled: true)
        }
        return switch ticketing.status {
        case "sales_open": State(title: "Sold out", enabled: false)
        case "sales_closed": State(title: "Sales ended", enabled: false)
        case "sales_paused": State(title: "Sales paused", enabled: false)
        default: State(title: "Not on sale yet", enabled: false)
        }
    }

    var body: some View {
        let state = Self.state(ticketing)
        Button(action: action) {
            HStack(spacing: 8) {
                if state.enabled { Image(systemName: "ticket").font(.body.weight(.semibold)) }
                Text(state.title)
                    .font(ClickTypography.button)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(state.enabled ? ClickColors.primaryActionForeground : ClickColors.textSecondary)
            .background(state.enabled ? ClickColors.primaryActionFill : ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!state.enabled)
    }
}
