import SwiftUI

/// The picker sheet's last step: waits for Click to confirm the order, then says how it ended
/// (copy matches web's checkout return page).
struct OrderConfirmationView: View {
    let model: OrderConfirmationModel
    /// "See your tickets".
    let onDone: () -> Void
    /// Back to the picker, selection kept.
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            icon
            Text(title)
                .font(ClickTypography.sectionTitle)
                .foregroundStyle(ClickColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(ClickTypography.body)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { actionButton(action) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ClickMotion.content, value: model.state)
        .sensoryFeedback(trigger: model.state) { _, state in
            switch state {
            case .confirmed: .success
            case .failed, .refunded: .error
            default: nil
            }
        }
        .task { await model.run() }
    }

    @ViewBuilder private var icon: some View {
        switch model.state {
        case .confirming:
            ProgressView().controlSize(.large).frame(height: 56)
        default:
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(model.state.isConfirmed ? ClickColors.success : ClickColors.textSecondary)
                .frame(height: 56)
                .accessibilityHidden(true)
        }
    }

    private var symbol: String {
        switch model.state {
        case .confirmed: "checkmark.circle.fill"
        case .stillConfirming: "clock"
        case .failed: "creditcard.trianglebadge.exclamationmark"
        case .refunded: "arrow.uturn.backward.circle"
        default: "circle.slash"
        }
    }

    private var title: String {
        switch model.state {
        case .confirming: "Confirming your order…"
        case .confirmed: "You’re in"
        case .canceled: "No charge was made"
        case .failed: "Payment didn’t go through"
        case .expired: "Checkout timed out"
        case .refunded: "Your payment was refunded"
        case .stillConfirming: "Still confirming…"
        }
    }

    private var message: String {
        switch model.state {
        case .confirming: "This usually takes a few seconds."
        case .confirmed(let count): count == 1 ? "Your ticket is ready." : "Your \(count) tickets are ready."
        case .canceled: "You left checkout before paying."
        case .failed: "No charge was made. You can try again with another card."
        case .expired: "Your tickets were released and no charge was made."
        case .refunded: "We couldn’t issue these tickets, so the charge was reversed in full."
        case .stillConfirming: "Your payment is still processing. Your tickets will show up on the event page as soon as it clears."
        }
    }

    private enum Action { case done(String), retry }

    private var action: Action? {
        switch model.state {
        case .confirming: nil
        case .confirmed: .done(model.state == .confirmed(ticketCount: 1) ? "See your ticket" : "See your tickets")
        case .canceled, .failed, .expired: .retry
        case .refunded, .stillConfirming: .done("Done")
        }
    }

    private func actionButton(_ action: Action) -> some View {
        let title: String
        let perform: () -> Void
        switch action {
        case .done(let label): title = label; perform = onDone
        case .retry: title = "Try again"; perform = onRetry
        }
        return Button(action: perform) {
            Text(title)
                .font(ClickTypography.button)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(ClickColors.primaryActionForeground)
                .background(ClickColors.primaryActionFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension OrderConfirmationModel.State {
    var isConfirmed: Bool {
        if case .confirmed = self { true } else { false }
    }
}
