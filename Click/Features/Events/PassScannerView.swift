import SwiftUI

/// The host's door: scan Click Passes to check people in. Every scan shows whose pass it is —
/// name and photo, to match against the face in front of you — and what that means: in, already
/// in (a shared screenshot), or not on the list. The server decides; nothing is assumed here.
struct PassScannerView: View {
    @Environment(AppEnvironment.self) private var env
    let beaconID: String

    private enum Outcome: Equatable {
        case scan(PassScan)
        case failed(String)
    }

    @State private var outcome: Outcome?
    @State private var isChecking = false
    /// The last code read and when: a pass held in frame isn't sent twice in a row.
    @State private var lastRead: (value: String, at: Date)?
    @State private var checkedInCount: Int?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRCameraView(deniedMessage: "Camera access is required to scan Click Passes.") { value in
                Task { await check(value) }
            }
            VStack {
                Spacer()
                Group {
                    if let outcome {
                        card(outcome)
                            .id(outcomeID(outcome))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        hint
                    }
                }
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.bottom, 24)
                .frame(maxWidth: 480)
            }
            .animation(ClickMotion.content, value: outcome)
        }
        .navigationTitle("Scan Passes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .keepsScreenAwake()
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Text(isChecking ? "Checking…" : "Scan a Click Pass")
                .font(ClickTypography.bodyEmphasized)
            Text(checkedInCount.map { "\($0) checked in so far" } ?? "Guests find it on the event page once they RSVP.")
                .font(ClickTypography.metadata)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
    }

    private func card(_ outcome: Outcome) -> some View {
        let look = Self.look(outcome)
        let holder = Self.holder(outcome)
        return VStack(spacing: 14) {
            if let holder {
                HStack(spacing: 14) {
                    AvatarView(imageURL: holder.avatarURL, seed: holder.userID, initials: Phase3Repository.initials(from: holder.name), size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(holder.name)
                            .font(ClickTypography.sectionTitle)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        if case .scan(let scan) = outcome, let tier = scan.tierName {
                            Text(tier)
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: look.symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(look.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.title)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                    if let detail = look.detail {
                        Text(detail)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if isChecking { ProgressView() }
            }
            .padding(12)
            .background(look.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ClickRadius.prominent, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private static func holder(_ outcome: Outcome) -> PassScan.Holder? {
        if case .scan(let scan) = outcome { return scan.holder }
        return nil
    }

    private struct Look {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String?
    }

    private static func look(_ outcome: Outcome) -> Look {
        switch outcome {
        case .failed(let message):
            return Look(symbol: "wifi.exclamationmark", tint: ClickColors.warning, title: "Couldn't check this pass", detail: message)
        case .scan(let scan):
            switch scan.result {
            case .checkedIn:
                return Look(symbol: "checkmark.circle.fill", tint: ClickColors.online, title: "Checked in",
                            detail: scan.checkInCount.map { "\($0) here now" })
            case .alreadyCheckedIn:
                return Look(symbol: "exclamationmark.triangle.fill", tint: ClickColors.warning, title: "Already checked in",
                            detail: scan.checkedInAt.map { "At \($0.formatted(date: .omitted, time: .shortened)). Make sure it's them." })
            case .notGoing:
                return Look(symbol: "xmark.octagon.fill", tint: ClickColors.destructive, title: "Not on the list",
                            detail: "Their RSVP isn't active for this event.")
            case .wrongEvent:
                return Look(symbol: "calendar.badge.exclamationmark", tint: ClickColors.warning, title: "Pass for another event", detail: nil)
            case .refunded:
                return Look(symbol: "arrow.uturn.backward.circle.fill", tint: ClickColors.destructive, title: "Refunded",
                            detail: "This ticket was refunded.")
            case .eventCancelled:
                return Look(symbol: "xmark.octagon.fill", tint: ClickColors.destructive, title: "Event cancelled",
                            detail: "Tickets for this event no longer admit anyone.")
            case .invalid:
                return Look(symbol: "qrcode", tint: ClickColors.destructive, title: "Not a Click Pass", detail: nil)
            }
        }
    }

    /// A new identity per scan, so the card re-enters even for the same person scanned twice.
    private func outcomeID(_ outcome: Outcome) -> String {
        switch outcome {
        case .failed(let message): "failed-\(message)"
        case .scan(let scan): "\(scan.holder?.userID ?? "none")-\(scan.result.rawValue)-\(lastRead?.at.timeIntervalSince1970 ?? 0)"
        }
    }

    private func check(_ value: String) async {
        guard !isChecking else { return }
        if let lastRead, lastRead.value == value, Date().timeIntervalSince(lastRead.at) < 3 { return }
        lastRead = (value, Date())
        isChecking = true
        defer { isChecking = false }
        do {
            let scan = try await env.events.scanPass(beaconID: beaconID, credential: value)
            if let count = scan.checkInCount { checkedInCount = count }
            switch scan.result {
            case .checkedIn: ClickHaptics.success()
            case .alreadyCheckedIn, .wrongEvent: ClickHaptics.warning()
            case .notGoing, .invalid, .refunded, .eventCancelled: ClickHaptics.error()
            }
            outcome = .scan(scan)
        } catch {
            guard !error.isCancellation else { return }
            // Let the same pass be tried again straight away.
            lastRead = nil
            ClickHaptics.error()
            outcome = .failed(error.userFacingMessage)
        }
    }
}
