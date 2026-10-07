import PassKit
import SwiftUI

/// Your Click Pass for an event you're going to: a ticket with the QR your host scans at the
/// door, your name and face (what the host matches against), and the things you need on the way
/// there — Wallet, Calendar, Directions and the host.
///
/// The pass is kept on the device, so it opens instantly and works in a basement with no signal.
/// While the event is on and you're not checked in yet, it quietly re-checks so the moment the
/// host scans you, the ticket turns to "You're in".
struct ClickPassView: View {
    @Environment(AppEnvironment.self) private var env
    let beaconID: String

    @State private var beacon: MapBeacon?
    @State private var pass: ClickPass?
    @State private var qrImage: UIImage?
    @State private var isNotGoing = false
    @State private var loadError: String?
    @State private var walletPass: PKPass?
    @State private var isInWallet = false
    /// This device can't add passes, or the signed pass couldn't be fetched: no Wallet slot.
    @State private var walletUnavailable = false
    @State private var directions: MapsDestination?
    @State private var calendar = CalendarButtonModel()

    var body: some View {
        Group {
            if let pass {
                content(pass)
            } else if isNotGoing {
                ContentUnavailableView {
                    Label("No pass yet", systemImage: "ticket")
                } description: {
                    Text("RSVP to the event and your Click Pass appears here.")
                } actions: {
                    Button("View Event") { env.router.navigate(to: .event(beaconID: beaconID)) }
                        .buttonStyle(.borderedProminent)
                        .tint(ClickColors.primaryActionFill)
                }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't load your pass", systemImage: "ticket")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(ClickColors.primaryActionFill)
                }
            } else {
                ClickLoadingView()
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Click Pass")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: seed)
        .task { await load() }
        .task(id: pass?.checkedInAt == nil && isAtTheDoor) { await watchForCheckIn() }
        .mapsDialog($directions)
        .calendarEditorSheet(calendar)
    }

    // MARK: - Ticket

    private func content(_ pass: ClickPass) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ticket(pass)
                actions(pass)
                Text("Your host scans this at the door. It's yours alone: if it's shared, the host sees your name and photo.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        // A dim screen is the usual reason a scan fails; a sleeping one is the other.
        .boostsScreenBrightness()
        .keepsScreenAwake()
    }

    private func ticket(_ pass: ClickPass) -> some View {
        VStack(spacing: 0) {
            EventVisual(seed: beaconID, imageURL: beacon?.imageURL, symbol: "calendar", cornerRadius: 0)
                .aspectRatio(2, contentMode: .fit)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text(beacon?.title ?? " ")
                    .font(ClickTypography.sectionTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let schedule = beacon?.schedule {
                    Label(EventFormatting.when(schedule), systemImage: "calendar")
                }
                if let place = beacon.flatMap({ $0.locationName ?? $0.formattedAddress }) {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .lineLimit(2)
                }
            }
            .font(ClickTypography.supporting)
            .foregroundStyle(ClickColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            PerforatedDivider()

            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white)
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                            .accessibilityLabel("Click Pass QR code, \(pass.code)")
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 260)
                .opacity(pass.checkedInAt == nil ? 1 : 0.35)
                .overlay {
                    if pass.checkedInAt != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, ClickColors.online)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(pass.code)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(ClickColors.textPrimary)
                    .textSelection(.enabled)

                holderRow(pass)
            }
            .padding(20)
        }
        .background(ClickColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.prominent, style: .continuous))
        .animation(ClickMotion.content, value: pass.checkedInAt)
    }

    private func holderRow(_ pass: ClickPass) -> some View {
        let me = env.selfData.profile.value
        return HStack(spacing: 12) {
            AvatarView(imageURL: me?.avatarURL, seed: env.session.currentSession?.userId ?? "", initials: me?.initials ?? "", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(me?.displayName ?? "You")
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(1)
                Text(status(pass))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(pass.checkedInAt == nil ? ClickColors.textSecondary : ClickColors.online)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func status(_ pass: ClickPass) -> String {
        if let at = pass.checkedInAt { return "You're in · checked in \(at.formatted(date: .omitted, time: .shortened))" }
        if beacon?.schedule?.isLive() == true { return "Going · show this at the door" }
        return "Going"
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ pass: ClickPass) -> some View {
        if pass.walletAvailable, !walletUnavailable {
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
                    // Holds the button's place while the signed pass downloads.
                    Capsule().fill(ClickColors.fillSubtle).frame(height: ClickMetrics.primaryActionHeight)
                }
            }
            .task { await loadWalletPass() }
        }
        if let beacon {
            HStack(spacing: 10) {
                if beacon.schedule != nil {
                    CalendarMenu(beacon: beacon, model: calendar) {
                        EventActionTile(title: calendar.isAdded ? "In Calendar" : "Calendar",
                                        systemImage: calendar.isAdded ? "calendar.badge.checkmark" : "calendar.badge.plus",
                                        tint: calendar.isAdded ? ClickColors.online : nil)
                    }
                }
                Button { directions = beacon.directions } label: {
                    EventActionTile(title: "Directions", systemImage: "location.north.line")
                }
                .buttonStyle(.plain)
                HostContactMenu(beacon: beacon) {
                    EventActionTile(title: "Contact", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
        }
    }

    // MARK: - Loading

    /// The event is on (or starts within the hour): the host may scan at any moment.
    private var isAtTheDoor: Bool {
        guard let schedule = beacon?.schedule else { return false }
        return schedule.start.timeIntervalSinceNow < 3600 && !schedule.isEnded()
    }

    private func seed() {
        if beacon == nil { beacon = env.beacons.cachedBeacon(id: beaconID)?.beacon }
        if pass == nil, let cached = env.events.cachedPass(beaconID: beaconID) { show(cached) }
    }

    private func show(_ fresh: ClickPass) {
        if fresh.credentialURL != pass?.credentialURL { qrImage = QRCodeRenderer.image(for: fresh.credentialURL) }
        if pass?.checkedInAt == nil, fresh.checkedInAt != nil, pass != nil {
            // The host just scanned you in.
            ClickHaptics.success()
            Task { await EventLiveActivities.setCheckedIn(true, beaconID: beaconID) }
        }
        pass = fresh
    }

    private func load() async {
        seed()
        loadError = nil
        async let beaconTask = fetchBeaconIfNeeded()
        do {
            show(try await env.events.pass(beaconID: beaconID))
            isNotGoing = false
        } catch APIError.forbidden {
            pass = nil
            isNotGoing = true
        } catch {
            // A pass already on the device stays usable offline.
            if pass == nil, !error.isCancellation { loadError = error.userFacingMessage }
        }
        let fetched = await beaconTask
        if let fetched { beacon = fetched }
    }

    private func fetchBeaconIfNeeded() async -> MapBeacon? {
        guard beacon == nil else { return nil }
        return try? await env.beacons.beacon(id: beaconID).beacon
    }

    private func watchForCheckIn() async {
        guard pass?.checkedInAt == nil, isAtTheDoor else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let fresh = try? await env.events.pass(beaconID: beaconID) else { continue }
            show(fresh)
            if fresh.checkedInAt != nil { return }
        }
    }

    private func loadWalletPass() async {
        guard walletPass == nil else { return }
        guard PKAddPassesViewController.canAddPasses() else {
            walletUnavailable = true
            return
        }
        do {
            let data = try await env.events.walletPass(beaconID: beaconID)
            let loaded = try PKPass(data: data)
            isInWallet = PKPassLibrary().containsPass(loaded)
            walletPass = loaded
        } catch {
            // The QR above works without Wallet; drop the slot rather than leave a dead placeholder.
            if !error.isCancellation { withAnimation(ClickMotion.subtleFade) { walletUnavailable = true } }
        }
    }
}

/// The ticket's tear line: a dashed rule between two notches cut into the card's edges.
private struct PerforatedDivider: View {
    private static let notch: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(ClickColors.background).frame(width: Self.notch, height: Self.notch).offset(x: -Self.notch / 2)
            Line()
                .stroke(ClickColors.separator, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 6]))
                .frame(height: 1.5)
            Circle().fill(ClickColors.background).frame(width: Self.notch, height: Self.notch).offset(x: Self.notch / 2)
        }
        .frame(height: Self.notch)
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: 0, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// Ways to reach an event's host: their Place page when a Place hosts it, a direct message when
/// they're your Click, and always the event chat (hosts are in it).
struct HostContactMenu<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations: ConversationListModel?
    let beacon: MapBeacon
    @ViewBuilder let label: () -> Content

    var body: some View {
        Menu {
            if let place = beacon.place, env.features.isEnabled(.clickPlaces) {
                Button("View \(place.name)", systemImage: "building.2") {
                    env.router.navigate(to: .place(idOrSlug: place.id, anchorToken: nil))
                }
            }
            if let host = conversations?.connection(userID: beacon.creatorID) {
                Button("Message \(HomeFeedModel.firstName(host.displayName) ?? host.displayName)", systemImage: "bubble.left") {
                    env.router.navigate(to: .chat(DirectChatRoute(
                        chatID: host.chatID, connectionID: host.connectionID, peerUserID: host.userID,
                        peerDisplayName: host.displayName, peerHandle: host.handle, peerAvatarURL: host.avatarUrl
                    )))
                }
            }
            Button("Ask in Event Chat", systemImage: "bubble.left.and.bubble.right") {
                env.router.navigate(to: .eventChat(beaconID: beacon.id))
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}

extension MapBeacon {
    /// Directions to the event's spot, labelled the way the page shows it.
    var directions: MapsDestination {
        MapsDestination(coordinate: coordinate, name: locationName ?? title, address: formattedAddress, wantsDirections: true)
    }
}

/// Apple's "Add to Apple Wallet" button. Wallet's own sheet is presented from the top-most view
/// controller as a standard page sheet: SwiftUI's `AddPassToWalletButton`, inside the event
/// sheet, laid it out in that sheet's frame (square top edge, the screen showing at the bottom).
private struct AddToWalletButton: UIViewRepresentable {
    let pass: PKPass
    /// Whether the pass is in Wallet once its sheet closes.
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKAddPassButton {
        let button = PKAddPassButton(addPassButtonStyle: .black)
        // Fills the row like the other actions instead of hugging its label.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.addTarget(context.coordinator, action: #selector(Coordinator.present(_:)), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: PKAddPassButton, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PKAddPassesViewControllerDelegate {
        var parent: AddToWalletButton

        init(_ parent: AddToWalletButton) {
            self.parent = parent
        }

        @objc func present(_ sender: UIView) {
            var presenter = sender.window?.rootViewController
            while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
                presenter = presented
            }
            guard let presenter, let controller = PKAddPassesViewController(pass: parent.pass) else { return }
            // A page sheet over everything, never laid out inside the event sheet's frame.
            controller.modalPresentationStyle = .pageSheet
            controller.delegate = self
            presenter.present(controller, animated: true)
        }

        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            let added = PKPassLibrary().containsPass(parent.pass)
            controller.dismiss(animated: true)
            parent.onFinish(added)
        }
    }
}
