import SwiftUI

/// The fifth root, "Me" (compatibility route `settings`): the user's identity/account home,
/// with preferences as pushed Settings pages (spec §65, prototype Me root).
///
/// Every server-backed control shows server truth: it never flips to a saved state until the
/// backend confirms, and a failed read is shown as unavailable rather than as "off".
public struct MeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MeTabAvatarModel.self) private var meTabAvatar: MeTabAvatarModel?
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.openURL) private var openURL

    @State private var profile = ModuleState<SelfProfile>()
    @State private var intents = ModuleState<[AvailabilityIntentPost]>()
    @State private var savedEvents = ModuleState<[SavedEvent]>()
    @State private var pendingFree: Bool?
    @State private var alertMessage: String?
    @State private var isEditingAvailability = false
    @State private var isEditingPhoto = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var isSigningOut = false
    @State private var showsCompactTitle = false

    public init() {}

    public var body: some View {
        List {
            identitySection
            if !conversations.core.isEmpty {
                coreSection
            }
            socialSection
            preferencesSection
            appearanceSection
            accountSection
            footer
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ClickColors.background.ignoresSafeArea())
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 190
        } action: { _, scrolledPastName in
            showsCompactTitle = scrolledPastName
        }
        .navigationTitle("Me")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(profile.value?.displayName ?? "Me")
                    .font(.headline)
                    .opacity(showsCompactTitle ? 1 : 0)
                    .animation(ClickMotion.subtleFade, value: showsCompactTitle)
            }
            ToolbarItem(placement: .topBarLeading) {
                RootMenu()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    env.router.navigate(to: .myQR)
                } label: {
                    Label("My QR", systemImage: "qrcode")
                }
                Button {
                    env.router.navigate(to: .settings(.editProfile))
                } label: {
                    Label("Edit profile", systemImage: "pencil")
                }
            }
        }
        .refreshable { await refresh() }
        .task { await bootstrap() }
        .sheet(isPresented: $isEditingAvailability) {
            AvailabilitySheet {
                Task { await loadIntents() }
            }
        }
        .sheet(isPresented: $isEditingPhoto) {
            AvatarUploadView(
                title: "Profile photo",
                subtitle: "Choose a photo from your library or take a new one.",
                skipTitle: "Cancel",
                onUpload: { data in try await uploadPhoto(data) },
                onSkip: { isEditingPhoto = false }
            )
        }
        .confirmationDialog("Sign out of Click?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { signOut() }
        }
        .confirmationDialog("Delete your Click account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Continue on joinclick.co", role: .destructive) { openAccountDeletion() }
        } message: {
            Text("Deleting your account permanently removes your profile, connections, and messages. For your security, you'll confirm deletion on joinclick.co while signed in there.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            VStack(spacing: 6) {
                if let status = activeStatus {
                    Button { isEditingAvailability = true } label: {
                        Text(status)
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(ClickColors.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Your availability: \(status)")
                }

                Button { isEditingPhoto = true } label: {
                    AvatarView(
                        imageURL: profile.value?.avatarURL,
                        seed: env.session.currentSession?.userId ?? "",
                        initials: profile.value?.initials ?? "",
                        size: 120
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ClickColors.primaryActionForeground)
                            .frame(width: 34, height: 34)
                            .background(ClickColors.primaryActionFill, in: Circle())
                            .overlay(Circle().stroke(ClickColors.background, lineWidth: 3))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change profile photo")
                .padding(.top, 4)

                Text(profile.value?.displayName ?? " ")
                    .font(ClickTypography.identityTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .redacted(reason: profile.value == nil ? .placeholder : [])
                    .padding(.top, 8)

                if let bio = profile.value?.bio {
                    Text(bio)
                        .font(ClickTypography.body)
                        .foregroundStyle(ClickColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if let summary = connectionSummary {
                    Text(summary)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                }

                if profile.value != nil {
                    OfflineNotice(showing: "saved profile", hasCachedValue: true, refreshFailed: profile.isStale) {
                        Task { await refresh() }
                    }
                    .padding(.top, 8)
                } else if profile.value == nil, profile.errorMessage != nil {
                    Button("Couldn't load your profile. Retry") {
                        Task { await refresh() }
                    }
                    .font(ClickTypography.supportingEmphasized)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        }
    }

    private var coreSection: some View {
        Section {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 16) {
                    ForEach(conversations.core) { item in
                        Button {
                            env.router.navigate(to: .userProfile(userID: item.userID, connectionID: item.connectionID))
                        } label: {
                            VStack(spacing: 6) {
                                AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: 64)
                                Text(HomeFeedModel.firstName(item.displayName) ?? item.displayName)
                                    .font(ClickTypography.supporting)
                                    .foregroundStyle(ClickColors.textPrimary)
                                    .lineLimit(1)
                            }
                            .frame(width: 70)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.displayName), Core")
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        } header: {
            HStack {
                Text("Core")
                Spacer()
                Button("View") { env.router.selectTab(.connections) }
                    .textCase(nil)
            }
        }
    }

    // MARK: - Social / availability

    private var socialSection: some View {
        Section {
            freeCurrentlyRow

            Button { isEditingAvailability = true } label: {
                SettingsRowLabel(title: "Availability post", systemImage: "hand.wave") {
                    Text(availabilitySummary)
                        .foregroundStyle(ClickColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            NavigationLink(value: AppRoute.savedEvents) {
                SettingsRowLabel(title: "Saved events", systemImage: "bookmark") {
                    if let count = savedEvents.value?.filter({ $0.isUpcomingOrLive() }).count {
                        Text(count, format: .number).foregroundStyle(ClickColors.textTertiary)
                    }
                }
            }

            NavigationLink(value: AppRoute.settings(.calendar)) {
                SettingsRowLabel(title: "Calendar", systemImage: "calendar") { EmptyView() }
            }
        }
    }

    @ViewBuilder
    private var freeCurrentlyRow: some View {
        if let serverValue = profile.value?.isFreeCurrently ?? (profile.value != nil ? false : nil) {
            Toggle(isOn: Binding(
                get: { pendingFree ?? serverValue },
                set: { newValue in Task { await setFreeCurrently(newValue) } }
            )) {
                SettingsRowLabel(title: "Free currently", subtitle: "Your Clicks can see you're up for plans", systemImage: "sun.max") { EmptyView() }
            }
            .disabled(pendingFree != nil)
        } else {
            SettingsRowLabel(title: "Free currently", subtitle: profile.isPending ? "Loading…" : "Unavailable right now", systemImage: "sun.max") {
                if profile.isPending { ProgressView() }
            }
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section {
            NavigationLink(value: AppRoute.settings(.alerts)) {
                SettingsRowLabel(title: "Alerts", systemImage: "bell") { EmptyView() }
            }
            NavigationLink(value: AppRoute.settings(.privacy)) {
                SettingsRowLabel(title: "Privacy & data", systemImage: "hand.raised") { EmptyView() }
            }
            NavigationLink(value: AppRoute.settings(.permissions)) {
                SettingsRowLabel(title: "Permissions", systemImage: "checkmark.shield") { EmptyView() }
            }
            NavigationLink(value: AppRoute.settings(.interests)) {
                SettingsRowLabel(title: "Interests", systemImage: "star") {
                    if let count = profile.value?.interests.count {
                        Text(count, format: .number).foregroundStyle(ClickColors.textTertiary)
                    }
                }
            }
            NavigationLink(value: AppRoute.settings(.personality)) {
                SettingsRowLabel(title: "Personality", systemImage: "sparkles") {
                    if let count = profile.value?.personality.count {
                        Text("\(count) of \(kPersonalityRequiredTagCount)").foregroundStyle(ClickColors.textTertiary)
                    }
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(selection: Binding(
                get: { env.settings.appearance },
                set: { env.settings.appearance = $0 }
            )) {
                ForEach(SettingsStore.Appearance.allCases) { Text($0.label).tag($0) }
            } label: {
                SettingsRowLabel(title: "Appearance", systemImage: "circle.lefthalf.filled") { EmptyView() }
            }
            .pickerStyle(.menu)
            Button {
                openURL(AppConfig.shared.apiBaseURL)
            } label: {
                SettingsRowLabel(title: "Web dashboard", systemImage: "globe") {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ClickColors.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var accountSection: some View {
        Section {
            Button {
                isConfirmingSignOut = true
            } label: {
                SettingsRowLabel(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    if isSigningOut { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut)

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                SettingsRowLabel(title: "Delete account", systemImage: "trash", tint: ClickColors.destructive) { EmptyView() }
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        Section {
            EmptyView()
        } footer: {
            Text("Click for iOS · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Derived copy

    private var activeStatus: String? {
        guard let first = intents.value?.first else { return nil }
        return "Down for \(first.tag.lowercased())"
    }

    private var availabilitySummary: String {
        guard let active = intents.value else { return intents.isPending ? "…" : "" }
        if active.isEmpty { return "None" }
        return active.map(\.tag).joined(separator: ", ")
    }

    private var connectionSummary: String? {
        guard let snapshot = conversations.snapshot else { return nil }
        let count = snapshot.connections.count + snapshot.archived.count
        return count == 1 ? "1 Click" : "\(count.formatted()) Clicks"
    }

    // MARK: - Loading and actions

    private var userID: String? { env.session.currentSession?.userId }

    private func bootstrap() async {
        guard let userID else { return }
        profile.seed(await env.me.cachedSelfProfile(userID: userID))
        intents.seed(await env.me.cachedIntents(userID: userID))
        savedEvents.seed(await env.beacons.cachedBookmarks(userID: userID))
        if let cached = profile.value {
            meTabAvatar?.update(avatarURL: cached.avatarURL)
        }
        await refresh()
    }

    private func refresh() async {
        async let profileLoad: Void = loadProfile()
        async let intentsLoad: Void = loadIntents()
        async let savedLoad: Void = loadSaved()
        _ = await (profileLoad, intentsLoad, savedLoad)
    }

    private func loadProfile() async {
        guard let userID else { return }
        profile.begin()
        do {
            let fresh = try await env.me.selfProfile(userID: userID)
            profile.succeed(fresh)
            meTabAvatar?.update(avatarURL: fresh.avatarURL)
            if let free = fresh.isFreeCurrently { env.settings.freeThisWeek = free }
        } catch {
            profile.fail(error)
        }
    }

    private func loadIntents() async {
        guard let userID else { return }
        intents.begin()
        do {
            intents.succeed(try await env.me.availabilityIntents(userID: userID))
        } catch {
            intents.fail(error)
        }
    }

    private func loadSaved() async {
        guard let userID else { return }
        savedEvents.begin()
        do {
            savedEvents.succeed(try await env.beacons.bookmarks(userID: userID))
        } catch {
            savedEvents.fail(error)
        }
    }

    private func setFreeCurrently(_ value: Bool) async {
        guard let current = profile.value else { return }
        pendingFree = value
        ClickHaptics.selection()
        defer { pendingFree = nil }
        do {
            let saved = try await env.me.setFreeCurrently(value)
            profile.succeed(current.with(isFreeCurrently: saved))
            env.settings.freeThisWeek = saved
        } catch {
            alertMessage = "\"Free currently\" wasn't changed. \(error.userFacingMessage)"
        }
    }

    private func uploadPhoto(_ data: Data) async throws {
        let url = try await env.avatarService.uploadAvatar(imageData: data, client: env.api)
        meTabAvatar?.update(avatarURL: url)
        isEditingPhoto = false
        await loadProfile()
    }

    private func signOut() {
        ClickHaptics.impact(.medium)
        isSigningOut = true
        Task {
            await env.session.signOut()
            isSigningOut = false
        }
    }

    /// Account deletion is completed on the web: `DELETE /api/user/delete` authenticates with
    /// web cookies, not the native bearer token (spec §65.14), so the app never calls it.
    private func openAccountDeletion() {
        guard var components = URLComponents(url: AppConfig.shared.apiBaseURL, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "tab", value: "settings")]
        if let url = components.url { openURL(url) }
    }
}

extension SelfProfile {
    func with(isFreeCurrently: Bool) -> SelfProfile {
        SelfProfile(
            userID: userID, firstName: firstName, lastName: lastName, displayName: displayName,
            avatarURL: avatarURL, interests: interests, personality: personality,
            isFreeCurrently: isFreeCurrently
        )
    }

    func with(interests: [String]? = nil, personality: [String]? = nil) -> SelfProfile {
        SelfProfile(
            userID: userID, firstName: firstName, lastName: lastName, displayName: displayName,
            avatarURL: avatarURL, interests: interests ?? self.interests,
            personality: personality ?? self.personality, isFreeCurrently: isFreeCurrently
        )
    }
}

/// A settings row label: leading symbol, title, optional subtitle, trailing accessory.
struct SettingsRowLabel<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    var tint: Color = ClickColors.textPrimary
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ClickTypography.body)
                    .foregroundStyle(tint)
                if let subtitle {
                    Text(subtitle)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
