import SwiftUI
import LocalAuthentication

private enum ApprovalAuthenticationError: Error {
    case unavailable
}

/// "Approve new sign-in?" on a device the user already has: shown when another device of theirs
/// asks for their past messages. Approving proves this device holds its key and shares the history
/// it has right away; "This wasn't me" denies it. Swiping down decides later.
struct DeviceApprovalSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let approval: ChatRepository.DeviceApproval

    private enum Phase: Equatable { case asking, approving, denying, approved, denied, failed(String) }
    @State private var phase: Phase = .asking

    private var deviceName: String { approval.deviceLabel ?? "device" }
    /// Browsers name themselves ("Chrome on Mac"); the apps name the device ("iPhone").
    private var isBrowser: Bool {
        guard let label = approval.deviceLabel else { return false }
        return label == "Web browser" || label.contains(" on ")
    }

    private var symbol: String {
        let label = approval.deviceLabel?.lowercased() ?? ""
        if label == "ipad" { return "ipad" }
        // Browsers say what they are ("Chrome on Mac"); a phone's browser still shows a phone.
        if label == "web browser" || label.contains(" on ") {
            return label.hasSuffix(" on iphone") || label.hasSuffix(" on android") ? "iphone" : "laptopcomputer"
        }
        return "iphone"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: phase == .denied ? "xmark.shield.fill" : (phase == .approved ? "checkmark.shield.fill" : symbol))
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(phase == .denied ? ClickColors.destructive : ClickColors.accentForeground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 76, height: 76)
                .glassCircleBackground()
                .padding(.top, 8)

            VStack(spacing: 8) {
                Text(title)
                    .font(ClickTypography.sectionTitle)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(ClickMotion.content, value: phase)

            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .presentationDetents([.height(440)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(phase == .approving || phase == .denying)
    }

    /// "An iPhone", "A web browser", "Chrome on Mac" (browsers name themselves), or "A new
    /// device" when an older build didn't say.
    static func withArticle(_ label: String?) -> String {
        guard let label, let first = label.first else { return "A new device" }
        if label.contains(" on ") { return label }
        let name = label == "Web browser" ? "web browser" : label
        return ("aeiou".contains(first.lowercased()) ? "An " : "A ") + name
    }

    private var title: String {
        switch phase {
        case .approved: "Approved"
        case .denied: "Not approved"
        default: "Approve new sign-in?"
        }
    }

    private var detail: String {
        switch phase {
        case .approved:
            if isBrowser, let label = approval.deviceLabel, label.contains(" on ") {
                let place = label.replacingOccurrences(of: " on ", with: " on your ")
                return "Your past messages will appear in \(place) in a moment."
            }
            return "Your past messages will appear on your \(isBrowser ? "browser" : deviceName) in a moment."
        case .denied:
            return "That \(isBrowser ? "browser" : deviceName) can't read your past messages. If you didn't sign in, change your password in Settings."
        case .failed(let message):
            return message
        default:
            let when = approval.createdAt.map { " \($0.formatted(.relative(presentation: .named)))" } ?? ""
            return "\(Self.withArticle(approval.deviceLabel)) signed in to your Click account\(when). Approve it to let it read your past messages."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .approved, .denied:
            Button { dismiss() } label: {
                Text("Done").font(ClickTypography.button).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(ClickColors.primaryActionFill)
        default:
            VStack(spacing: 6) {
                Button { Task { await decide(approve: true) } } label: {
                    ZStack {
                        Text("Approve").opacity(phase == .approving ? 0 : 1)
                        if phase == .approving { ProgressView().tint(ClickColors.primaryActionForeground) }
                    }
                    .font(ClickTypography.button)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(ClickColors.primaryActionFill)
                .disabled(phase == .approving || phase == .denying)

                Button(role: .destructive) { Task { await decide(approve: false) } } label: {
                    Text(phase == .denying ? "Denying…" : "This wasn't me")
                        .font(ClickTypography.button)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ClickColors.destructive)
                .disabled(phase == .approving || phase == .denying)
            }
        }
    }

    private func decide(approve: Bool) async {
        guard let userID = env.session.currentSession?.userId else { return }
        phase = approve ? .approving : .denying
        do {
            if approve {
                // OS-managed Face ID / Touch ID, falling back to the device passcode.
                // Authentication is required again for each approval; cancellation never approves.
                let context = LAContext()
                context.localizedCancelTitle = "Cancel"
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                    throw ApprovalAuthenticationError.unavailable
                }
                try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Confirm that you want to share Click message history with this device."
                )
                // A session switch while the system prompt was open must never approve the old account.
                guard env.session.currentSession?.userId == userID else {
                    phase = .asking
                    return
                }
            }
            try await env.chat.decideDeviceApproval(id: approval.id, approve: approve, currentUserID: userID)
            withAnimation(ClickMotion.content) { phase = approve ? .approved : .denied }
            approve ? ClickHaptics.success() : ClickHaptics.impact(.medium)
            env.deviceApprovalDecided(approval.id)
            await ClickNotificationCoordinator.shared.reconcileDeviceApprovalNotifications(completedRequestID: approval.id)
        } catch {
            if let authError = error as? LAError,
               authError.code == .userCancel || authError.code == .systemCancel || authError.code == .appCancel {
                phase = .asking
                return
            }
            guard !error.isCancellation else { phase = .asking; return }
            withAnimation(ClickMotion.content) {
                phase = .failed(error is LAError || error is ApprovalAuthenticationError
                    ? "Device authentication is required to approve this request."
                    : "Couldn't reach Click. Check your connection and try again.")
            }
        }
    }
}

/// On a device waiting for permission to read past messages (atop Clicks): how to unlock them,
/// with the emailed link as the fallback and "Ask again" after a denial. Gone once approved.
struct DeviceHistoryBanner: View {
    @Environment(AppEnvironment.self) private var env
    @State private var busy = false
    @State private var emailed = false

    var body: some View {
        if let own = env.ownDeviceApproval, own.status != .approved {
            let denied = own.status == .denied
            let expired = own.expired
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: denied ? "lock.trianglebadge.exclamationmark.fill" : "lock.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClickColors.accentForeground)
                    .frame(width: 36, height: 36)
                    .glassCircleBackground()
                VStack(alignment: .leading, spacing: 4) {
                    Text(denied ? "Older messages stay locked" : "Unlock older messages")
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                    Text(subtitle(denied: denied, expired: expired, emailSent: own.emailSent || emailed))
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = action(denied: denied, expired: expired, emailSent: own.emailSent || emailed) {
                        Button(action.title) { Task { await action.run() } }
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.accentForeground)
                            .disabled(busy)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .groupedSurface()
            .accessibilityElement(children: .contain)
            .transition(.opacity)
        }
    }


    private func subtitle(denied: Bool, expired: Bool, emailSent: Bool) -> String {
        if denied { return "Your other device didn't approve this one." }
        if expired { return "The approval request expired." }
        if emailSent { return "Approve it in Click on a device you already use, or with the link we emailed you." }
        return "Approve this \(UIDevice.current.model) in Click on a device you already use."
    }

    private func action(denied: Bool, expired: Bool, emailSent: Bool) -> (title: String, run: () async -> Void)? {
        if denied || expired {
            return ("Ask again", { await run { _ = try await env.chat.askForHistory(reopen: true) } })
        }
        if !emailSent, let id = env.ownDeviceApproval?.id {
            return ("Email me a link instead", {
                await run {
                    _ = try await env.chat.emailDeviceApprovalLink(id: id)
                    emailed = true
                }
            })
        }
        return nil
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        try? await body()
        env.refreshDeviceApprovals()
    }
}
