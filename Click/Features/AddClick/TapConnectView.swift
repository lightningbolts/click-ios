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
            case .choosingPeople(let candidates, let selected):
                choosePeople(candidates, selected: selected)
            case .connected(let match):
                // Only after the server confirmed the connection (spec §28).
                PostConnectView(
                    model: PostConnectModel(match: match, method: .tap),
                    onSayHi: { peer in openChat(peer, connectionID: peer.connectionID ?? match.connectionID) },
                    onViewProfile: { peer in
                        env.router.navigate(to: .userProfile(userID: peer.id, connectionID: peer.connectionID ?? match.connectionID))
                    },
                    onOpenGroups: { env.router.selectTab(.connections) },
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
        .toolbar(.hidden, for: .tabBar)
        .task { model.attach(env) }
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
        case .choosingPeople, .confirmingPeople: "Creating your group…"
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

    // MARK: - Multi-Tap host selection

    private func choosePeople(_ candidates: [ProximityPeer], selected: Set<String>) -> some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(candidates) { peer in
                        Button { model.toggleSelection(peer) } label: {
                            HStack(spacing: 14) {
                                AvatarView(imageURL: peer.avatarURL, seed: peer.id, initials: peer.initials, size: 46)
                                Text(peer.name)
                                    .font(ClickTypography.body)
                                    .foregroundStyle(ClickColors.textPrimary)
                                Spacer()
                                Image(systemName: selected.contains(peer.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(selected.contains(peer.id) ? ClickColors.accentForeground : ClickColors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected.contains(peer.id) ? .isSelected : [])
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Who was in this tap?")
                            .font(ClickTypography.largeTitle)
                            .foregroundStyle(ClickColors.textPrimary)
                            .textCase(nil)
                        Text("Choose who to connect with. Nothing is created until you confirm.")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textTertiary)
                            .textCase(nil)
                    }
                    .padding(.bottom, 10)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)

            VStack(spacing: 10) {
                Button(selected.count == 1 ? "Connect with 1 person" : "Connect with \(selected.count) people") {
                    model.confirmSelection()
                }
                .buttonStyle(.clickPrimary)
                .disabled(selected.isEmpty)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.clickSecondary)
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.bottom, 16)
        }
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
