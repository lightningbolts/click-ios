import PassKit
import SwiftUI

/// What a ticket shows at the door: its QR, or why it no longer admits.
enum TicketDisplay: Equatable {
    case qr
    case checkedIn(Date?)
    case refunded
    case cancelled
    case void
}

/// The pass screen for a ticketed event: one card per ticket, paged sideways when there are several.
struct TicketPassContent: View {
    @Environment(AppEnvironment.self) private var env
    let beacon: MapBeacon?
    let beaconID: String
    let tickets: [OwnedTicket]
    let fetchedAt: Date
    let cancelled: Bool

    @State private var page: String?
    @State private var qrImages: [String: UIImage] = [:]

    static func ticketDisplay(_ ticket: OwnedTicket, cancelled: Bool) -> TicketDisplay {
        if cancelled { return .cancelled }
        switch ticket.status {
        case .valid: return ticket.credentialURL == nil ? .void : .qr
        case .checkedIn: return .checkedIn(ticket.checkedInAt)
        case .refunded: return .refunded
        case .void: return .void
        }
    }

    /// Shown once the tickets on screen are more than a minute old (offline, or refresh failed).
    static func updatedLine(fetchedAt: Date, now: Date = .now) -> String? {
        let age = now.timeIntervalSince(fetchedAt)
        guard age > 60 else { return nil }
        if age < 3600 { return "Updated \(Int(age / 60)) min ago" }
        if age < 86_400 { return "Updated \(Int(age / 3600)) hr ago" }
        return "Updated \(fetchedAt.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var current: OwnedTicket? {
        tickets.first { $0.id == page } ?? tickets.first
    }

    var body: some View {
        VStack(spacing: 16) {
            if tickets.count == 1, let ticket = tickets.first {
                card(ticket)
            } else {
                pager
            }
            if let updated = Self.updatedLine(fetchedAt: fetchedAt) {
                Label(updated, systemImage: "arrow.clockwise")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
            }
            if let current {
                if Self.ticketDisplay(current, cancelled: cancelled) == .qr {
                    TicketWalletButton(beaconID: beaconID, ticketID: current.id)
                        .id(current.id)
                }
                orderDetails(current)
            }
        }
        .onChange(of: tickets.map(\.credentialURL), initial: true) { renderCodes() }
    }

    private var pager: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(tickets) { ticket in
                        card(ticket).containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            .scrollClipDisabled()

            let index = (tickets.firstIndex { $0.id == current?.id } ?? 0) + 1
            Text("\(index) of \(tickets.count)")
                .font(ClickTypography.supportingEmphasized.monospacedDigit())
                .foregroundStyle(ClickColors.textSecondary)
                .contentTransition(.numericText())
                .animation(ClickMotion.content, value: index)
        }
    }

    private func card(_ ticket: OwnedTicket) -> some View {
        let display = Self.ticketDisplay(ticket, cancelled: cancelled)
        return VStack(spacing: 0) {
            PassHeader(beacon: beacon, beaconID: beaconID)
            PerforatedDivider()
            VStack(spacing: 14) {
                if display == .qr {
                    PassQRTile(image: qrImages[ticket.id], label: "Ticket QR code, \(ticket.ticketNumber)", maxWidth: 300)
                } else {
                    status(display)
                }
                VStack(spacing: 4) {
                    Text(ticket.tierName)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(ticket.ticketNumber)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(ClickColors.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .background(ClickColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.prominent, style: .continuous))
        .animation(ClickMotion.content, value: display)
    }

    private func status(_ display: TicketDisplay) -> some View {
        let (symbol, title, message, tint): (String, String, String, Color) = switch display {
        case .qr: ("qrcode", "", "", ClickColors.textSecondary)
        case .checkedIn(let at):
            ("checkmark.circle.fill", "You’re in",
             at.map { "Checked in at \($0.formatted(date: .omitted, time: .shortened))." } ?? "This ticket was checked in.", ClickColors.online)
        case .refunded: ("arrow.uturn.backward.circle", "Refunded", "This ticket was refunded.", ClickColors.textSecondary)
        case .cancelled: ("xmark.circle", "Event cancelled", "Tickets for this event no longer admit anyone.", ClickColors.textSecondary)
        case .void: ("slash.circle", "No longer valid", "This ticket can’t be used.", ClickColors.textSecondary)
        }
        return VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(ClickTypography.bodyEmphasized)
                .foregroundStyle(ClickColors.textPrimary)
            Text(message)
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func orderDetails(_ ticket: OwnedTicket) -> some View {
        DisclosureGroup {
            VStack(spacing: 10) {
                detailLine("Ticket", ticket.ticketNumber)
                detailLine("Type", ticket.tierName)
                detailLine("Order", String(ticket.orderID.prefix(8)).uppercased())
            }
            .padding(.top, 10)
        } label: {
            Text("Order details")
                .font(ClickTypography.bodyEmphasized)
                .foregroundStyle(ClickColors.textPrimary)
        }
        .tint(ClickColors.textSecondary)
        .padding(14)
        .detailCard()
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(ClickColors.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(ClickColors.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(ClickTypography.supporting)
    }

    /// Codes render once per credential, never per frame.
    private func renderCodes() {
        for ticket in tickets {
            guard let url = ticket.credentialURL else { qrImages[ticket.id] = nil; continue }
            if qrImages[ticket.id] == nil { qrImages[ticket.id] = QRCodeRenderer.image(for: url) }
        }
    }
}

/// "Add to Apple Wallet" for one ticket, or "View in Wallet" once it's there.
private struct TicketWalletButton: View {
    @Environment(AppEnvironment.self) private var env
    let beaconID: String
    let ticketID: String
    @State private var walletPass: PKPass?
    @State private var isInWallet = false
    @State private var unavailable = !PKAddPassesViewController.canAddPasses()

    var body: some View {
        if !unavailable {
            Group {
                if let walletPass, isInWallet {
                    Button {
                        if let url = walletPass.passURL { UIApplication.shared.open(url) }
                    } label: {
                        Label("View in Wallet", systemImage: "wallet.pass")
                    }
                    .buttonStyle(.clickSecondary)
                } else if let walletPass {
                    AddToWalletButton(pass: walletPass) { added in
                        if added { isInWallet = true }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: ClickMetrics.primaryActionHeight)
                } else {
                    Capsule().fill(ClickColors.fillSubtle).frame(height: ClickMetrics.primaryActionHeight)
                }
            }
            .task {
                do {
                    let loaded = try PKPass(data: try await env.ticketing.walletPass(beaconID: beaconID, ticketID: ticketID))
                    isInWallet = PKPassLibrary().containsPass(loaded)
                    walletPass = loaded
                } catch {
                    // The QR works without Wallet; drop the slot rather than leave a dead placeholder.
                    if !error.isCancellation { withAnimation(ClickMotion.subtleFade) { unavailable = true } }
                }
            }
        }
    }
}
