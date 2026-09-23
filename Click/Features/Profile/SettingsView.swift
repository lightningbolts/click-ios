import SwiftUI

/// Self/account surface. The Me tab is settings-first, matching the shipping Click product,
/// rather than reusing the peer-profile presentation.
public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var data: Phase3ProfileData?
    @State private var refreshError: String?
    @State private var isSigningOut = false
    @State private var notificationRequestInFlight = false

    public init() {}

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if refreshError != nil {
                    savedStateBanner
                }

                profileHeader

                settingsSection("Availability") {
                    settingsToggleRow(
                        title: "Free currently",
                        subtitle: "Show your connections that you're open to plans.",
                        systemImage: "bolt.fill",
                        isOn: Binding(
                            get: { env.settings.freeThisWeek },
                            set: { env.settings.freeThisWeek = $0 }
                        )
                    )
                }

                settingsSection("Alerts") {
                    VStack(spacing: 0) {
                        settingsToggleRow(
                            title: "Message notifications",
                            subtitle: nil,
                            systemImage: "message.fill",
                            isOn: Binding(
                                get: { env.settings.messageNotificationsEnabled },
                                set: { newValue in
                                    env.settings.messageNotificationsEnabled = newValue
                                    if newValue {
                                        notificationRequestInFlight = true
                                        Task {
                                            _ = await ClickNotificationCoordinator.shared.requestAuthorization()
                                            notificationRequestInFlight = false
                                        }
                                    }
                                }
                            )
                        )

                        Divider().padding(.leading, 52)

                        settingsToggleRow(
                            title: "Ambient sound enrichment",
                            subtitle: "Short ambient sample at connect time. No recordings stored.",
                            systemImage: "waveform",
                            isOn: Binding(
                                get: { env.settings.ambientNoiseOptIn },
                                set: { env.settings.ambientNoiseOptIn = $0 }
                            )
                        )
                    }
                }

                settingsSection("Privacy & data") {
                    VStack(spacing: 0) {
                        Button {
                            env.permissions.openSystemSettings()
                        } label: {
                            settingInfoRow(
                                title: "Permissions Hub",
                                subtitle: "Review camera, microphone, location, contacts, and Bluetooth access.",
                                systemImage: "hand.raised.fill"
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 52)

                        settingsToggleRow(
                            title: "Barometric context",
                            subtitle: "Add approximate vertical context to an encounter when available.",
                            systemImage: "arrow.up.and.down",
                            isOn: Binding(
                                get: { env.settings.barometricContextOptIn },
                                set: { env.settings.barometricContextOptIn = $0 }
                            )
                        )
                    }
                }

                if let profile = data?.profile, !profile.interests.isEmpty {
                    settingsSection("Interests") {
                        tagCloud(profile.interests, emphasized: true)
                            .padding(14)
                    }
                }

                if let profile = data?.profile, !profile.personalityTraits.isEmpty {
                    settingsSection("Personality") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("My personality")
                                .font(ClickTypography.titleSmall)
                            tagCloud(profile.personalityTraits, emphasized: false)
                        }
                        .padding(14)
                    }
                }

                settingsSection("Appearance") {
                    settingsToggleRow(
                        title: "Dark mode",
                        subtitle: "Use Click's dark appearance.",
                        systemImage: "moon.fill",
                        isOn: Binding(
                            get: { env.settings.darkModeEnabled },
                            set: { env.settings.darkModeEnabled = $0 }
                        )
                    )
                }

                Button(role: .destructive, action: signOut) {
                    HStack(spacing: 10) {
                        if isSigningOut {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        Text("Sign out")
                            .font(ClickTypography.labelLarge)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(ClickColors.error.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ClickColors.error.opacity(0.55), lineWidth: 1)
                    }
                }
                .disabled(isSigningOut)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task { await bootstrap() }
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private var profileHeader: some View {
        if let profile = data?.profile {
            HStack(spacing: 14) {
                avatar(profile)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(ClickColors.primary, lineWidth: 2)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(ClickTypography.headlineSmall)
                        .foregroundStyle(ClickColors.textPrimary)

                    if !profile.handle.isEmpty {
                        Text(profile.handle)
                            .font(ClickTypography.bodyMedium)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 12) {
                Circle()
                    .fill(ClickColors.surfaceContainerHigh)
                    .frame(width: 72, height: 72)
                    .overlay { ProgressView() }
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ClickColors.surfaceContainerHigh)
                        .frame(width: 150, height: 18)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ClickColors.surfaceContainerHigh)
                        .frame(width: 110, height: 14)
                }
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textPrimary)
                .padding(.horizontal, 2)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ClickColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(ClickColors.quietBorder.opacity(0.65), lineWidth: 1)
                }
        }
    }

    private func settingsToggleRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? ClickColors.primary : ClickColors.textSecondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(ClickTypography.captionSmall)
                        .foregroundStyle(ClickColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(ClickColors.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, subtitle == nil ? 12 : 11)
    }

    private func settingInfoRow(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ClickColors.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(subtitle)
                    .font(ClickTypography.captionSmall)
                    .foregroundStyle(ClickColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ClickColors.tertiaryLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func tagCloud(_ tags: [String], emphasized: Bool) -> some View {
        SettingsFlowLayout(spacing: 7) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(ClickTypography.labelMedium)
                    .foregroundStyle(emphasized ? ClickColors.primary : ClickColors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(emphasized ? ClickColors.primaryFixed.opacity(0.22) : ClickColors.surfaceContainerLow)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().stroke(
                            emphasized ? ClickColors.primary.opacity(0.5) : ClickColors.quietBorder.opacity(0.55),
                            lineWidth: 1
                        )
                    }
            }
        }
    }

    @ViewBuilder
    private func avatar(_ profile: UserProfileSnapshot) -> some View {
        if let raw = profile.avatarUrl, let url = URL(string: raw) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackAvatar(profile)
            }
        } else {
            fallbackAvatar(profile)
        }
    }

    private func fallbackAvatar(_ profile: UserProfileSnapshot) -> some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.32))
            .overlay {
                Text(profile.initials)
                    .font(ClickTypography.headlineSmall)
                    .foregroundStyle(ClickColors.primary)
            }
    }

    private var savedStateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Offline — showing the last saved profile")
                .font(ClickTypography.captionSmall)
            Spacer()
            Button("Retry") { Task { await refresh() } }
                .font(ClickTypography.captionSmall)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ClickColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ClickColors.quietBorder.opacity(0.6), lineWidth: 1)
        }
    }

    @MainActor
    private func bootstrap() async {
        guard let userID = env.session.currentSession?.userId else { return }
        if let cached = await env.phase3.cachedProfile(for: userID) {
            data = cached
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard let userID = env.session.currentSession?.userId else { return }
        do {
            data = try await env.phase3.refreshSelfProfile(userID: userID)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await env.session.signOut()
            isSigningOut = false
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
