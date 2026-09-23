import SwiftUI

/// Self/account surface. The landing page follows the shipping Click settings hierarchy, while
/// each destination uses native controls and persists through SettingsStore / existing APIs.
public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MeTabAvatarModel.self) private var meTabAvatar: MeTabAvatarModel?

    @State private var data: Phase3ProfileData?
    @State private var refreshError: String?
    @State private var isSigningOut = false

    public init() {}

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if refreshError != nil {
                    offlineNotice
                }

                profileCard

                VStack(spacing: 0) {
                    SettingsNavigationRow(
                        title: "Availability",
                        subtitle: "Free this week and intent posts",
                        systemImage: "calendar.badge.checkmark"
                    ) {
                        AvailabilitySettingsView()
                    }

                    Divider().padding(.leading, 60)

                    SettingsNavigationRow(
                        title: "Alerts",
                        subtitle: "Messages, events, hubs",
                        systemImage: "bell.fill"
                    ) {
                        AlertSettingsView()
                    }

                    Divider().padding(.leading, 60)

                    SettingsNavigationRow(
                        title: "Privacy & data",
                        subtitle: "Ghost mode, location, permissions",
                        systemImage: "shield.lefthalf.filled"
                    ) {
                        PrivacySettingsView()
                    }

                    Divider().padding(.leading, 60)

                    SettingsNavigationRow(
                        title: "Interests",
                        subtitle: "Common Ground tags",
                        systemImage: "star.fill"
                    ) {
                        TagSettingsView(
                            title: "Interests",
                            tags: data?.profile.interests ?? [],
                            emphasized: true
                        )
                    }

                    Divider().padding(.leading, 60)

                    SettingsNavigationRow(
                        title: "Personality",
                        subtitle: "The traits that describe you",
                        systemImage: "sparkles"
                    ) {
                        TagSettingsView(
                            title: "Personality",
                            tags: data?.profile.personalityTraits ?? [],
                            emphasized: false
                        )
                    }

                    Divider().padding(.leading, 60)

                    SettingsRouteRow(
                        title: "Saved events",
                        subtitle: "Bookmarks from Home and the map",
                        systemImage: "bookmark.fill",
                        route: .savedEvents
                    )

                    Divider().padding(.leading, 60)

                    SettingsNavigationRow(
                        title: "Appearance",
                        subtitle: env.settings.darkModeEnabled ? "Dark" : "Light",
                        systemImage: "circle.lefthalf.filled"
                    ) {
                        AppearanceSettingsView()
                    }
                }

                Button(role: .destructive, action: signOut) {
                    HStack(spacing: 12) {
                        if isSigningOut {
                            ProgressView()
                                .controlSize(.small)
                                .tint(ClickColors.destructive)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        Text("Sign out")
                            .font(ClickTypography.bodyEmphasized)
                        Spacer()
                    }
                    .padding(.horizontal, ClickSpacing.surfacePadding)
                    .frame(minHeight: ClickMetrics.rowMinHeight)
                    .foregroundStyle(ClickColors.destructive)
                    .groupedSurface()
                }
                .buttonStyle(.plain)
                .disabled(isSigningOut)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Me")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                } label: {
                    Label("Me menu", systemImage: "ellipsis")
                }
            }
        }
        .task { await bootstrap() }
        .refreshable { await refresh() }
    }

    private var profileCard: some View {
        VStack(spacing: 14) {
            if let profile = data?.profile {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(
                        imageURL: profile.avatarUrl,
                        initials: profile.initials,
                        size: ClickMetrics.Avatar.identity
                    )

                    ZStack {
                        Circle()
                            .fill(ClickColors.primaryActionFill)
                            .frame(width: 36, height: 36)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(ClickColors.primaryActionForeground)
                    }
                    .accessibilityHidden(true)
                }

                VStack(spacing: 3) {
                    Text(profile.displayName)
                        .font(ClickTypography.identityTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                    if !profile.handle.isEmpty {
                        Text(profile.handle)
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                }

                NavigationLink {
                    EditProfileSettingsView(profile: profile)
                } label: {
                    Text("Edit Profile")
                }
                .buttonStyle(.clickSecondary)
            } else {
                ProgressView()
                    .tint(ClickColors.accentForeground)
                    .frame(height: 180)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .groupedSurface()
    }

    private var offlineNotice: some View {
        OfflineNotice("Offline — showing saved profile") {
            Task { await refresh() }
        }
    }

    @MainActor
    private func bootstrap() async {
        guard let userID = env.session.currentSession?.userId else { return }
        if let cached = await env.phase3.cachedProfile(for: userID) {
            data = cached
            meTabAvatar?.update(avatarURL: cached.profile.avatarUrl)
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard let userID = env.session.currentSession?.userId else { return }
        do {
            let fresh = try await env.phase3.refreshSelfProfile(userID: userID)
            data = fresh
            meTabAvatar?.update(avatarURL: fresh.profile.avatarUrl)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func signOut() {
        ClickHaptics.impact(.medium)
        isSigningOut = true
        Task {
            await env.session.signOut()
            isSigningOut = false
        }
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

/// A settings row that pushes a typed `AppRoute`, so its destination can push further routes
/// on the same path-driven stack.
private struct SettingsRouteRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let route: AppRoute

    var body: some View {
        NavigationLink(value: route) {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(ClickColors.textSecondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(subtitle)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClickColors.textTertiary)
        }
        .frame(minHeight: ClickMetrics.rowMinHeight)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct AvailabilitySettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Free this week",
                    isOn: Binding(
                        get: { env.settings.freeThisWeek },
                        set: { env.settings.freeThisWeek = $0 }
                    )
                )
                .tint(ClickColors.accentForeground)
            } footer: {
                Text("Your active intent posts are managed from Home under “I’m down for…”.")
            }
        }
        .navigationTitle("Availability")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AlertSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isRequesting = false

    var body: some View {
        Form {
            Section("Messages") {
                Toggle(
                    "Message notifications",
                    isOn: Binding(
                        get: { env.settings.messageNotificationsEnabled },
                        set: { newValue in
                            env.settings.messageNotificationsEnabled = newValue
                            if newValue {
                                isRequesting = true
                                Task {
                                    _ = await ClickNotificationCoordinator.shared.requestAuthorization()
                                    isRequesting = false
                                }
                            }
                        }
                    )
                )
                .tint(ClickColors.accentForeground)

                if isRequesting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Updating notification permission…")
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                }
            }

            Section {
                Toggle(
                    "Ambient sound enrichment",
                    isOn: Binding(
                        get: { env.settings.ambientNoiseOptIn },
                        set: { env.settings.ambientNoiseOptIn = $0 }
                    )
                )
                .tint(ClickColors.accentForeground)
            } header: {
                Text("Context")
            } footer: {
                Text("Ambient samples enrich encounter context. Click does not store recordings.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section("Encounter context") {
                Toggle(
                    "Barometric context",
                    isOn: Binding(
                        get: { env.settings.barometricContextOptIn },
                        set: { env.settings.barometricContextOptIn = $0 }
                    )
                )
                .tint(ClickColors.accentForeground)
            }

            Section {
                Button {
                    env.permissions.openSystemSettings()
                } label: {
                    Label("Permissions Hub", systemImage: "hand.raised.fill")
                }
            } header: {
                Text("System access")
            } footer: {
                Text("Review camera, microphone, location, contacts, notifications, and Bluetooth permissions in iOS Settings.")
            }
        }
        .navigationTitle("Privacy & data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TagSettingsView: View {
    let title: String
    let tags: [String]
    let emphasized: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title == "Interests" ? "Common Ground tags" : "The traits that describe you")
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textSecondary)

                SettingsFlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(emphasized ? ClickColors.accentForeground : ClickColors.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: ClickMetrics.chipHeight)
                            .background(
                                emphasized ? ClickColors.selectionTint : ClickColors.fillSubtle,
                                in: Capsule()
                            )
                    }
                }

                if tags.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "tag",
                        description: Text("Your onboarding selections will appear here.")
                    )
                }
            }
            .padding(18)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Dark mode",
                    isOn: Binding(
                        get: { env.settings.darkModeEnabled },
                        set: { env.settings.darkModeEnabled = $0 }
                    )
                )
                .tint(ClickColors.accentForeground)
            } footer: {
                Text("This preference is shared with the previous Click iOS build during the native migration.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SavedEventsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: [SavedEventRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView()
                    .tint(ClickColors.accentForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "No saved events",
                    systemImage: "bookmark",
                    description: Text(errorMessage ?? "Events you bookmark from Home or the map appear here.")
                )
            } else {
                List(items) { item in
                    NavigationLink(value: AppRoute.event(beaconID: item.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(ClickTypography.body)
                            if let location = item.location, !location.isEmpty {
                                Text(location)
                                    .font(ClickTypography.metadata)
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                            if let start = item.start {
                                Text(start, style: .date)
                                    .font(ClickTypography.caption)
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Saved events")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let request = APIRequest(
                path: "/api/me/event-bookmarks",
                method: .get,
                queryItems: [URLQueryItem(name: "limit", value: "100")],
                requiresAuth: true
            )
            let (data, _) = try await env.api.executeRaw(request)
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rows = root["bookmarks"] as? [[String: Any]]
            else { throw APIError.decoding }

            items = rows.compactMap { row in
                guard let id = row["beacon_id"] as? String else { return nil }
                let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let location =
                    (row["location_name"] as? String)
                    ?? (row["formatted_address"] as? String)
                let start = (row["event_start_at"] as? String).flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }
                return SavedEventRow(
                    id: id,
                    title: title?.isEmpty == false ? title! : "Saved event",
                    location: location,
                    start: start
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SavedEventRow: Identifiable {
    let id: String
    let title: String
    let location: String?
    let start: Date?
}

private struct EditProfileSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    let profile: UserProfileSnapshot

    @State private var displayName: String
    @State private var isSaving = false
    @State private var message: String?

    init(profile: UserProfileSnapshot) {
        self.profile = profile
        self._displayName = State(initialValue: profile.displayName)
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name", text: $displayName)
                    .textContentType(.name)
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save changes")
                    }
                }
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }

            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(message == "Saved" ? ClickColors.online : ClickColors.destructive)
                }
            }
        }
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func save() async {
        guard let userID = env.session.currentSession?.userId else { return }
        let clean = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let parts = clean.split(separator: " ", maxSplits: 1).map(String.init)
        var payload: [String: Any] = [
            "first_name": parts.first ?? clean
        ]
        if parts.count > 1 {
            payload["last_name"] = parts[1]
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let request = APIRequest(
                path: "/api/users/\(userID)/profile",
                method: .patch,
                body: body,
                requiresAuth: true
            )
            _ = try await env.api.executeRaw(request)
            message = "Saved"
            ClickHaptics.success()
        } catch {
            message = error.localizedDescription
            ClickHaptics.error()
        }
    }
}

private struct SettingsFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
