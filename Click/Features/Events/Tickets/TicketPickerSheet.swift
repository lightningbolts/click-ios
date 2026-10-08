import SwiftUI

/// Choose tickets for an event, then claim them or go to checkout.
struct TicketPickerSheet: View {
    @State private var model: TicketPickerModel
    /// Called with the order once Click has started it.
    let onStart: (CheckoutStart) -> Void
    @Environment(\.dismiss) private var dismiss

    init(beaconID: String, client: any TicketingClient, onStart: @escaping (CheckoutStart) -> Void) {
        _model = State(initialValue: TicketPickerModel(beaconID: beaconID, client: client))
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading where model.offerings.isEmpty:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message) where model.offerings.isEmpty:
                    ContentUnavailableView {
                        Label("Tickets didn’t load", systemImage: "ticket")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.load() } }
                    }
                default:
                    picker
                }
            }
            .background(ClickColors.surface)
            .navigationTitle("Tickets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: model.selection)
        .task { await model.load() }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    ForEach(Array(model.offerings.enumerated()), id: \.element.id) { index, offering in
                        if index > 0 { Divider().overlay(ClickColors.separator).padding(.leading, 14) }
                        row(offering)
                    }
                }
                .detailCard()

                if model.mixesKinds {
                    Text("Free and paid tickets are separate orders.")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                }
                if let message = model.notice ?? failure {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.count > 0 { summary }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            cta
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ClickColors.surface)
        }
    }

    private var failure: String? {
        if case .failed(let message) = model.phase { message } else { nil }
    }

    private func row(_ offering: TicketOffering) -> some View {
        let onSale = offering.availability == .onSale
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(offering.name)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(onSale ? ClickColors.textPrimary : ClickColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail(offering))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                if let description = offering.description, !description.isEmpty {
                    Text(description)
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if onSale { stepper(offering) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func detail(_ offering: TicketOffering) -> String {
        let price = TicketPrice.money(offering.unitAmount, currency: offering.currency)
        switch offering.availability {
        case .onSale:
            guard let remaining = offering.remaining else { return price }
            return "\(price) · \(remaining) left"
        case .soldOut: return "\(price) · Sold out"
        case .ended: return "\(price) · Sales ended"
        case .paused: return "\(price) · Sales paused"
        case .notStarted:
            guard let start = offering.salesStartAt else { return "\(price) · Not on sale yet" }
            return "\(price) · On sale \(start.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    private func stepper(_ offering: TicketOffering) -> some View {
        HStack(spacing: 4) {
            stepButton("minus", label: "Fewer \(offering.name)", enabled: model.quantity(offering.id) > 0) {
                model.decrement(offering.id)
            }
            Text("\(model.quantity(offering.id))")
                .font(ClickTypography.bodyEmphasized.monospacedDigit())
                .foregroundStyle(ClickColors.textPrimary)
                .frame(minWidth: 24)
                .accessibilityLabel("\(model.quantity(offering.id)) \(offering.name)")
            stepButton("plus", label: "More \(offering.name)", enabled: model.canIncrement(offering.id)) {
                model.increment(offering.id)
            }
        }
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(enabled ? ClickColors.textPrimary : ClickColors.textTertiary)
                .background(ClickColors.fillStrong.opacity(enabled ? 1 : 0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var summary: some View {
        VStack(spacing: 8) {
            ForEach(model.offerings.filter { model.quantity($0.id) > 0 }) { offering in
                line("\(model.quantity(offering.id)) × \(offering.name)",
                     TicketPrice.money(offering.unitAmount * model.quantity(offering.id), currency: offering.currency))
            }
            line("Fees", "None")
            Divider().overlay(ClickColors.separator)
            line("Total", model.isFree ? "Free" : TicketPrice.money(model.total, currency: model.currency), emphasized: true)
        }
        .padding(14)
        .detailCard()
    }

    private func line(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(emphasized ? ClickColors.textPrimary : ClickColors.textSecondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(ClickColors.textPrimary).monospacedDigit()
        }
        .font(emphasized ? ClickTypography.bodyEmphasized : ClickTypography.supporting)
    }

    private var cta: some View {
        let submitting = model.phase == .submitting
        return Button {
            Task { if let start = await model.submit() { onStart(start) } }
        } label: {
            HStack(spacing: 8) {
                if submitting { ProgressView().tint(ClickColors.primaryActionForeground) }
                Text(model.ctaTitle).font(ClickTypography.button)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(ClickColors.primaryActionForeground)
            .background(ClickColors.primaryActionFill, in: Capsule())
            .opacity(model.count == 0 ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(model.count == 0 || submitting)
    }
}
