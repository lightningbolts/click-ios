import SwiftUI

/// People you already know who are on Click. Contacts are hashed on the device before matching;
/// a Connect sends a friend request the other person answers from their Activity.
struct FindFriendsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var isSearching = false
    /// Nil until a search finished: the screen offers the search instead of results.
    @State private var matches: [DiscoveredContactCard]?
    /// Contacts on Click you're already connected with (left out of `matches`).
    @State private var alreadyConnected = 0
    /// Contacts on Click with a request pending either way (also left out of `matches`).
    @State private var pending = 0
    /// Nil until loaded; the "let friends find you" card shows while you have no number saved.
    @State private var myPhone: String??
    @State private var requested: Set<String> = []
    @State private var knownSince: [String: PriorKnownSince] = [:]
    @State private var errorMessage: String?
    @State private var contactsDenied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ClickSpacing.lg) {
                if myPhone == .some(nil) {
                    phoneCard
                }
                if let matches {
                    results(matches)
                } else {
                    intro
                }
                if let errorMessage {
                    VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                        FormNotice(text: errorMessage)
                        if contactsDenied {
                            Button("Open Settings") { env.permissions.openSystemSettings() }
                                .font(ClickTypography.supportingEmphasized)
                                .foregroundStyle(ClickColors.accentForeground)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                privacyNote
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .safeAreaInset(edge: .bottom) {
            if matches == nil {
                Button(action: search) {
                    if isSearching { ProgressView() } else { Text("Find friends from contacts") }
                }
                .buttonStyle(.clickPrimary)
                .disabled(isSearching)
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.vertical, ClickSpacing.sm)
                .background(ClickColors.background)
            }
        }
        .animation(ClickMotion.content, value: matches)
        .animation(ClickMotion.content, value: myPhone)
        .task {
            guard myPhone == nil else { return }
            if let phone = try? await ContactDiscoveryService.shared.myPhone(client: env.api) {
                myPhone = .some(phone)
            }
        }
        .animation(ClickMotion.subtleFade, value: errorMessage)
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Find friends")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(spacing: ClickSpacing.sm) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ClickColors.accentForeground)
                .frame(width: 64, height: 64)
                .background(ClickColors.selectionTint, in: Circle())
            Text("See who you already know")
                .font(ClickTypography.sectionTitle)
                .foregroundStyle(ClickColors.textPrimary)
            Text("Connect with friends from your contacts who are on Click. They'll get a request they can accept or ignore.")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ClickSpacing.lg)
        .padding(.horizontal, ClickSpacing.surfacePadding)
        .groupedSurface()
    }

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: ClickSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Let friends find you")
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                Text("Most people save friends by phone number. Add yours so they can find you here. It's never shown to anyone.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }
            // The card stays until you leave, so the number you just saved shows here.
            MyPhoneEditor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ClickSpacing.surfacePadding)
        .groupedSurface()
    }

    private var emptyTitle: String {
        switch (alreadyConnected, pending) {
        case (0, 0): "None of your contacts are on Click yet"
        case (0, _): pending == 1
            ? "1 contact on Click, with a request waiting"
            : "\(pending) contacts on Click, with requests waiting"
        case (1, _): "1 contact on Click, and you're already connected"
        default: "\(alreadyConnected) contacts on Click, and you're already connected"
        }
    }

    @ViewBuilder
    private func results(_ matches: [DiscoveredContactCard]) -> some View {
        if matches.isEmpty {
            VStack(spacing: ClickSpacing.xs) {
                Text(emptyTitle)
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(alreadyConnected + pending > 0
                     ? "Invite others, or connect in person with Tap or your QR code."
                     : "Invite them, or connect in person with Tap or your QR code.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: ClickSpacing.sm) {
                    InviteFriendsLink()
                    Button("Tap to Connect") { env.router.navigate(to: .tapConnect) }
                        .buttonStyle(.clickSecondary)
                }
                .padding(.top, ClickSpacing.sm)
            }
            .frame(maxWidth: .infinity)
            .padding(ClickSpacing.surfacePadding)
            .groupedSurface()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionTitle(matches.count == 1 ? "1 friend on Click" : "\(matches.count) friends on Click")
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                        if index > 0 { HomeDivider(inset: 76) }
                        row(match)
                    }
                }
                .groupedSurface()
                InviteFriendsLink().padding(.top, ClickSpacing.xs)
            }
        }
    }

    private func row(_ match: DiscoveredContactCard) -> some View {
        let isRequested = requested.contains(match.id)
        return HStack(spacing: 12) {
            AvatarView(imageURL: match.avatarUrl, seed: match.id,
                       initials: Phase3Repository.initials(from: match.name), size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.name)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(1)
                // How you know each other travels with the request.
                Menu {
                    Picker("Known since", selection: knownSinceBinding(match.id)) {
                        ForEach(PriorKnownSince.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(knownSinceLabel(match.id))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textSecondary)
                }
                .disabled(isRequested)
            }
            Spacer(minLength: 8)
            Button(isRequested ? "Requested" : "Connect") { connect(match.id) }
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(isRequested ? ClickColors.textSecondary : ClickColors.primaryActionForeground)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(isRequested ? ClickColors.fillSubtle : ClickColors.primaryActionFill, in: Capsule())
                .frame(minHeight: ClickMetrics.minimumHitTarget)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .disabled(isRequested)
                .animation(ClickMotion.selection, value: isRequested)
        }
        .padding(.horizontal, ClickSpacing.surfacePadding)
        .padding(.vertical, 10)
    }

    private var privacyNote: some View {
        Label("Phone numbers and emails are hashed on your phone before matching. Click never uploads or stores your contacts.",
              systemImage: "lock.fill")
            .font(ClickTypography.caption)
            .foregroundStyle(ClickColors.textTertiary)
            .padding(.horizontal, 4)
    }

    private func knownSinceLabel(_ userID: String) -> String {
        guard let since = knownSince[userID], since != .unspecified else { return "How do you know them?" }
        return "Known since \(since.label.lowercased())"
    }

    private func knownSinceBinding(_ userID: String) -> Binding<PriorKnownSince> {
        Binding(get: { knownSince[userID] ?? .unspecified }, set: { knownSince[userID] = $0 })
    }

    private func search() {
        ClickHaptics.impact(.medium)
        isSearching = true
        errorMessage = nil
        Task {
            defer { isSearching = false }
            guard await env.permissions.requestPermission(for: .contacts).isAuthorized else {
                contactsDenied = true
                errorMessage = "Click needs Contacts access to find your friends."
                return
            }
            contactsDenied = false
            do {
                let hashes = try await ContactDiscoveryService.shared.collectAndHashDeviceContacts()
                let response = try await ContactDiscoveryService.shared.discoverMatches(hashes: hashes, client: env.api)
                alreadyConnected = response.alreadyConnected
                pending = response.pending
                matches = response.matches
                AvatarView.prefetch(matches?.map(\.avatarUrl) ?? [], size: 48)
                ClickHaptics.success()
            } catch {
                errorMessage = "Couldn't check your contacts. Try again."
                ClickHaptics.error()
            }
        }
    }

    private func connect(_ userID: String) {
        ClickHaptics.impact(.light)
        requested.insert(userID)
        errorMessage = nil
        Task {
            do {
                try await ContactDiscoveryService.shared.requestPriorConnection(
                    targetUserId: userID,
                    knownSince: knownSince[userID] ?? .unspecified,
                    contextTag: nil,
                    client: env.api
                )
                ClickHaptics.success()
            } catch {
                requested.remove(userID)
                errorMessage = "Couldn't send that request. Try again."
                ClickHaptics.error()
            }
        }
    }
}

/// Texts (or shares) the App Store link to people not on Click yet. Hidden until the app is
/// live: `CLICK_APP_STORE_URL` is empty before launch.
struct InviteFriendsLink: View {
    var body: some View {
        if let url = AppConfig.shared.appStoreURL {
            ShareLink(item: url, message: Text("I'm on Click. Come find me:")) {
                Label("Invite friends", systemImage: "message")
            }
            .buttonStyle(.clickSecondary)
        }
    }
}
