import SwiftUI

/// The Tap to Connect flow (route `.tapConnect`). Every visible state is a real state of
/// `TapConnectModel`; nothing is simulated in production builds.
struct TapConnectView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var model = TapConnectModel()

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .choosingPeople(let review):
                PeopleReviewView(
                    review: review, isConfirming: false, verification: model.verification,
                    onToggle: model.toggleRemoval, onConfirm: model.confirmSelection,
                    onSkip: model.skipTap, onCancel: model.cancel
                )
                .transition(.opacity)
            case .confirmingPeople(let review):
                PeopleReviewView(
                    review: review, isConfirming: true, verification: model.verification,
                    onToggle: { _ in }, onConfirm: {}, onSkip: {}, onCancel: model.cancel
                )
            case .connected(let match):
                // Only after the server confirmed the connection (spec §28).
                PostConnectView(
                    model: PostConnectModel(match: match, method: .tap, verification: model.verification, notice: model.resultNotice),
                    onSayHi: { peer in openChat(peer, connectionID: peer.connectionID ?? match.connectionID) },
                    onViewProfile: { peer in
                        env.router.navigate(to: .userProfile(userID: peer.id, connectionID: peer.connectionID ?? match.connectionID))
                    },
                    onOpenGroup: { group in
                        env.router.addClickPath.removeAll()
                        env.router.selectTab(.connections)
                        if let group { env.router.navigate(to: .groupChat(group.chatRoute)) }
                    },
                    onOpenEvent: { env.router.navigate(to: .event(beaconID: $0)) },
                    onDone: { dismiss() }
                )
                .id(match.connectionID ?? match.peers.map(\.id).joined())
                .transition(.opacity)
            default:
                statusContent
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if DebugLaunch.has("-connection-log") { ConnectionDebugLogView() }
        }
        .navigationTitle("Tap to Connect")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.attach(env)
            model.warmUp()
        }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.enterBackground()
            case .active: model.enterForeground()
            default: break
            }
        }
        .onChange(of: connectedID) { _, id in
            if id != nil { Task { await conversations.refresh() } }
        }
    }

    private var connectedID: String? {
        if case .connected(let match) = model.phase { return match.connectionID ?? match.peers.first?.id }
        return nil
    }

    // MARK: - Status

    private var statusContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    emblem
                        .padding(.top, 36)
                    Text(title)
                        .font(ClickTypography.identityTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(ClickTypography.body)
                        .foregroundStyle(ClickColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsFactors {
                        factorList
                            .padding(.top, 26)
                    }
                }
                .padding(.horizontal, ClickSpacing.screenGutter)
            }
            actions
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var emblem: some View {
        if case .connected(let match) = model.phase, let peer = match.peers.first {
            AvatarView(imageURL: peer.avatarURL, seed: peer.id, initials: peer.initials, size: 120)
                .transition(.scale.combined(with: .opacity))
        } else {
            ZStack {
                if model.phase == .sensing, !reduceMotion {
                    PulseRings()
                }
                Circle()
                    .fill(ClickColors.primaryActionFill)
                    .frame(width: 120, height: 120)
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(ClickColors.primaryActionForeground)
            }
            .frame(width: 200, height: 200)
            .accessibilityHidden(true)
        }
    }

    private var symbol: String {
        switch model.phase {
        case .failed, .needsPermission: "exclamationmark"
        case .waitingForPeer, .savedOffline: "clock"
        default: "wave.3.right"
        }
    }

    private var title: String {
        switch model.phase {
        case .idle: "Ready to Connect"
        case .preparing: "Getting ready…"
        case .needsPermission(.microphone): "Microphone needed"
        case .needsPermission(.bluetooth): "Bluetooth needed"
        case .needsPermission(.bluetoothOff): "Turn on Bluetooth"
        case .sensing: "Searching…"
        case .submitting: "Checking your tap…"
        case .waitingForPeer: "Tap saved"
        case .choosingPeople, .confirmingPeople: "Who's in this Click?"
        case .connected(let match): match.isNewConnection ? "You're connected" : "Encounter saved"
        case .savedOffline: "Saved offline"
        case .failed: "Couldn't connect"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle:
            "Hold phones close together and both tap Start. Bluetooth, a short inaudible tone, and your location confirm you're really together."
        case .preparing:
            "Click asks for access only when you start a tap."
        case .needsPermission(.microphone):
            "Tap to Connect listens for a short inaudible tone. Nothing is recorded or stored."
        case .needsPermission(.bluetooth):
            "Tap to Connect uses Bluetooth to find the other phone."
        case .needsPermission(.bluetoothOff):
            "Turn on Bluetooth in Control Center, then try again."
        case .sensing:
            "Keep your phones close together."
        case .submitting:
            "Click is confirming you were really together."
        case .waitingForPeer(let exhausted):
            exhausted
                ? "Their tap hasn't arrived yet. The Click appears in your inbox as soon as it does."
                : "Waiting for the other person's tap to arrive…"
        case .choosingPeople, .confirmingPeople:
            ""
        case .connected(let match):
            connectedSubtitle(match)
        case .savedOffline:
            "Click will finish this connection when you're back online."
        case .failed(let message):
            message
        }
    }

    private func connectedSubtitle(_ match: ProximityMatch) -> String {
        let names = match.peers.map { HomeFeedModel.firstName($0.name) ?? $0.name }
        let joined = ListFormatter.localizedString(byJoining: names)
        if !match.isNewConnection { return "You and \(joined) are already connected. This encounter was added to your timeline." }
        return match.isGroup ? "You're in a verified group with \(joined)." : "You and \(joined) just Clicked."
    }

    private var showsFactors: Bool {
        switch model.phase {
        case .sensing, .submitting, .failed: model.bluetooth != .waiting
        default: false
        }
    }

    private var factorList: some View {
        VStack(spacing: 0) {
            FactorRow(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", status: model.bluetooth)
            Divider().padding(.leading, 60)
            FactorRow(title: "Sound", symbol: "waveform", status: model.sound)
            Divider().padding(.leading, 60)
            FactorRow(title: "Location", symbol: "location", status: model.location)
        }
        .groupedSurface()
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .idle:
                Button("Start") { model.start() }
                    .buttonStyle(.clickPrimary)
                Text("Nothing is recorded. Click only checks that you're really together.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
                    .multilineTextAlignment(.center)
            case .preparing, .sensing, .submitting, .confirmingPeople:
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.clickSecondary)
            case .needsPermission(let issue):
                if issue == .bluetoothOff {
                    Button("Try again") { model.start() }
                        .buttonStyle(.clickPrimary)
                } else {
                    Button("Open Settings") { env.permissions.openSystemSettings() }
                        .buttonStyle(.clickPrimary)
                }
                qrFallback
            case .waitingForPeer:
                Button("Done") { dismiss() }
                    .buttonStyle(.clickSecondary)
            case .connected(let match):
                if !match.isGroup, let peer = match.peers.first {
                    Button("Say hi") { openChat(peer, connectionID: match.connectionID) }
                        .buttonStyle(.clickPrimary)
                } else {
                    Button("Open Clicks") { env.router.selectTab(.connections) }
                        .buttonStyle(.clickPrimary)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.clickSecondary)
            case .savedOffline:
                Button("Done") { dismiss() }
                    .buttonStyle(.clickSecondary)
            case .failed:
                Button("Try again") { model.start() }
                    .buttonStyle(.clickPrimary)
                qrFallback
            case .choosingPeople:
                EmptyView()
            }
        }
    }

    private var qrFallback: some View {
        Button("Use my QR instead") {
            env.router.navigate(to: .myQR)
        }
        .buttonStyle(.clickSecondary)
    }

    private func openChat(_ peer: ProximityPeer, connectionID: String?) {
        env.router.addClickPath.removeAll()
        env.router.selectTab(.connections)
        env.router.connectionsPath = [.chat(DirectChatRoute(
            connectionID: connectionID ?? peer.connectionID,
            peerUserID: peer.id,
            peerDisplayName: peer.name,
            peerAvatarURL: peer.avatarURL
        ))]
    }
}

/// Everyone this tap found, before anything is saved: who you're connecting with, each with a
/// Remove button, and anyone removed in their own section with Add back. Same row anatomy as
/// Find Friends; same bottom bar as the post-connect screen.
private struct PeopleReviewView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let review: TapConnectModel.PeopleReview
    let isConfirming: Bool
    let verification: ConnectionVerification?
    let onToggle: (ProximityPeer) -> Void
    let onConfirm: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    private static let avatarSize: CGFloat = 48
    private static let dividerInset: CGFloat = ClickSpacing.surfacePadding + avatarSize + 12

    private var included: [ProximityPeer] { review.selected }
    private var removed: [ProximityPeer] { review.candidates.filter { review.removed.contains($0.id) } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 20)

                section(
                    included.isEmpty ? "Connecting with" : "Connecting with · \(included.count)",
                    people: included, isRemoved: false
                ) {
                    Text("Everyone's removed. Add someone back, or skip this Click.")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ClickSpacing.surfacePadding)
                }
                .padding(.top, 28)

                if !removed.isEmpty {
                    section("Not connecting", people: removed, isRemoved: true) { EmptyView() }
                        .padding(.top, 24)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Text(footnote)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .padding(.horizontal, 12)
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.bottom, 24)
            .animation(reduceMotion ? ClickMotion.subtleFade : ClickMotion.content, value: review.removed)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { actions }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            emblem
            Text("Who's in this Click?")
                .font(ClickTypography.identityTitle)
                .foregroundStyle(ClickColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 12)
                .fixedSize(horizontal: false, vertical: true)
            if let verification, !verification.summary.isEmpty {
                Label(verification.summary, systemImage: "checkmark.shield.fill")
                    .font(ClickTypography.metadataEmphasized)
                    .foregroundStyle(ClickColors.accentForeground)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .background(ClickColors.selectionTint, in: Capsule())
                    .padding(.top, 12)
                    .accessibilityLabel("Verified nearby: \(verification.summary)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The tap flow's emblem, smaller: the people themselves are in the rows below.
    private var emblem: some View {
        Image(systemName: "person.3.fill")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(ClickColors.primaryActionForeground)
            .frame(width: 64, height: 64)
            .background(ClickColors.primaryActionFill, in: Circle())
            .accessibilityHidden(true)
    }

    // MARK: Rows

    private func section<Empty: View>(
        _ title: String, people: [ProximityPeer], isRemoved: Bool, @ViewBuilder empty: () -> Empty
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.textSecondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                .contentTransition(.numericText())
            VStack(spacing: 0) {
                if people.isEmpty {
                    empty()
                }
                ForEach(Array(people.enumerated()), id: \.element.id) { index, peer in
                    if index > 0 { HomeDivider(inset: Self.dividerInset) }
                    row(peer, isRemoved: isRemoved)
                }
            }
            .groupedSurface()
        }
    }

    private func row(_ peer: ProximityPeer, isRemoved: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(imageURL: peer.avatarURL, seed: peer.id, initials: peer.initials, size: Self.avatarSize)
                .opacity(isRemoved ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(isRemoved ? ClickColors.textSecondary : ClickColors.textPrimary)
                    .lineLimit(1)
                Text(status(peer, isRemoved: isRemoved))
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(isRemoved ? "Add back" : "Remove") { onToggle(peer) }
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(isRemoved ? ClickColors.accentForeground : ClickColors.textPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(isRemoved ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
                .frame(minHeight: ClickMetrics.minimumHitTarget)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .disabled(isConfirming)
                .accessibilityLabel(isRemoved ? "Add \(peer.name) back" : "Remove \(peer.name)")
        }
        .padding(.horizontal, ClickSpacing.surfacePadding)
        .padding(.vertical, 10)
        .frame(minHeight: ClickMetrics.rowMinHeight)
    }

    private func status(_ peer: ProximityPeer, isRemoved: Bool) -> String {
        if isRemoved { return "Won't be connected with you" }
        return peer.isNewConnection == false ? "Already connected" : "New connection"
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                included.isEmpty ? onSkip() : onConfirm()
            } label: {
                HStack(spacing: 8) {
                    if isConfirming { ProgressView() }
                    Text(primaryTitle)
                }
            }
            .buttonStyle(.clickPrimary)
            .disabled(isConfirming)
            Button("Cancel", action: onCancel)
                .font(ClickTypography.supportingEmphasized)
                .padding(.top, 2)
        }
        .padding(.horizontal, ClickSpacing.screenGutter)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Copy

    private var subtitle: String {
        if review.existingConnectionID != nil {
            return "You're already a group. Remove anyone who isn't here, then save this Click."
        }
        return "Remove anyone you don't want to connect with."
    }

    private var footnote: String {
        "Nothing is saved until you confirm. You can add tags on the next screen."
    }

    private var primaryTitle: String {
        if isConfirming { return review.isExistingGroup ? "Saving…" : "Connecting…" }
        if included.isEmpty { return "Skip this Click" }
        if review.isExistingGroup { return "Save this Click" }
        if included.count == 1 { return "Connect with \(HomeFeedModel.firstName(included[0].name) ?? included[0].name)" }
        return "Connect with \(included.count) people"
    }
}

private struct FactorRow: View {
    let title: String
    let symbol: String
    let status: TapConnectModel.FactorStatus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .foregroundStyle(status == .found ? ClickColors.online : ClickColors.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(ClickTypography.body)
                .foregroundStyle(ClickColors.textPrimary)
            Spacer()
            switch status {
            case .waiting:
                Text("Waiting").foregroundStyle(ClickColors.textTertiary)
            case .active:
                ProgressView()
            case .found:
                Label("Detected", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(ClickColors.online)
            case .none:
                Text("Not detected").foregroundStyle(ClickColors.textTertiary)
            case .skipped(let reason):
                Text(reason).foregroundStyle(ClickColors.textTertiary)
            }
        }
        .font(ClickTypography.supporting)
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

/// Expanding rings while sensors are listening. Shown only in the sensing state and never
/// with Reduce Motion.
private struct PulseRings: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .fill(ClickColors.primaryActionFill.opacity(0.35))
                    .frame(width: 120, height: 120)
                    .scaleEffect(expanded ? 1.65 : 1)
                    .opacity(expanded ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(index) * 0.8),
                        value: expanded
                    )
            }
        }
        .onAppear { expanded = true }
    }
}

#if DEBUG
/// `-preview-tap-review`: the group review row with sample people, for layout checks.
struct TapReviewPreviewHost: View {
    @State private var review = TapConnectModel.PeopleReview(candidates: [
        ProximityPeer(id: "p1", name: "Maya Chen", avatarURL: nil, connectionID: nil, isNewConnection: true),
        ProximityPeer(id: "p2", name: "Jordan Lee", avatarURL: nil, connectionID: nil, isNewConnection: false),
        ProximityPeer(id: "p3", name: "Sam Ortiz", avatarURL: nil, connectionID: nil, isNewConnection: true),
        ProximityPeer(id: "p4", name: "Priya Patel", avatarURL: nil, connectionID: nil, isNewConnection: true),
        ProximityPeer(id: "p5", name: "Alex Kim", avatarURL: nil, connectionID: nil, isNewConnection: true)
    ])

    var body: some View {
        NavigationStack {
            PeopleReviewView(
                review: review, isConfirming: false,
                verification: ConnectionVerification(signals: ["Bluetooth", "Sound", "Location"], locationAccuracyMeters: 6),
                onToggle: { peer in
                    if review.removed.contains(peer.id) { review.removed.remove(peer.id) } else { review.removed.insert(peer.id) }
                },
                onConfirm: {}, onSkip: {}, onCancel: {}
            )
            .background(ClickColors.background.ignoresSafeArea())
            .navigationTitle("Tap to Connect")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// `-preview-tap-connected`: the group result (tags + encounter details) with sample people.
struct TapConnectedPreviewHost: View {
    var body: some View {
        NavigationStack {
            PostConnectView(
                model: PostConnectModel(
                    match: ProximityMatch(
                        connectionID: "g1", isNewConnection: true, isGroup: true,
                        peers: ["Maya Chen", "Jordan Lee", "Sam Ortiz"].enumerated().map {
                            ProximityPeer(id: "p\($0.offset)", name: $0.element, avatarURL: nil, connectionID: "g1", isNewConnection: true)
                        },
                        groupMemberIDs: [], encounterLogged: true
                    ),
                    method: .tap,
                    verification: ConnectionVerification(signals: ["Bluetooth", "Sound", "Location"], locationAccuracyMeters: 6)
                ),
                onSayHi: { _ in }, onViewProfile: { _ in }, onOpenGroup: { _ in }, onOpenEvent: { _ in }, onDone: {}
            )
            .environment(ConversationListModel())
            .navigationTitle("Tap to Connect")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
