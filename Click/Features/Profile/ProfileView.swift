import SwiftUI

/// Native user profile surface with one canonical avatar/header vocabulary and restrained Click
/// Functional Clarity surfaces.
public struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    private let requestedUserID: String?
    private let connectionID: String?

    @State private var data: Phase3ProfileData?
    @State private var refreshError: String?
    @State private var isSigningOut = false

    public init(
        userID: String? = nil,
        connectionID: String? = nil,
        initialProfile: UserProfileSnapshot? = nil
    ) {
        self.requestedUserID = userID
        self.connectionID = connectionID
        self._data = State(
            initialValue: initialProfile.map {
                Phase3ProfileData(profile: $0, timeline: [])
            }
        )
    }

    private var resolvedUserID: String? {
        requestedUserID ?? env.session.currentSession?.userId
    }

    private var isSelf: Bool {
        guard let resolvedUserID,
              let current = env.session.currentSession?.userId else {
            return false
        }
        return resolvedUserID == current
    }

    public var body: some View {
        Group {
            if let data {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if refreshError != nil {
                            cachedBanner
                        }

                        profileHeader(data.profile)

                        if isSelf {
                            statsStrip(data.profile)
                        }

                        if !data.profile.interests.isEmpty {
                            tagSection(
                                title: "Interests",
                                tags: data.profile.interests,
                                emphasized: true
                            )
                        }

                        if !data.profile.personalityTraits.isEmpty {
                            tagSection(
                                title: "Personality",
                                tags: data.profile.personalityTraits,
                                emphasized: false
                            )
                        }

                        if !data.timeline.isEmpty {
                            timelineSection(data.timeline)
                        }

                        if isSelf {
                            accountActions
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .refreshable { await refresh() }
            } else {
                loadingState
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle(isSelf ? "Me" : (data?.profile.displayName ?? "Profile"))
        .navigationBarTitleDisplayMode(isSelf ? .large : .inline)
        .tint(ClickColors.primary)
        .task { await bootstrap() }
    }

    private func profileHeader(_ profile: UserProfileSnapshot) -> some View {
        HStack(spacing: 16) {
            avatar(profile)
                .frame(width: 78, height: 78)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(ClickColors.primary.opacity(0.72), lineWidth: 1.5)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(ClickTypography.headlineSmall)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(2)

                if !profile.handle.isEmpty {
                    Text(profile.handle)
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                if !profile.memberSince.isEmpty {
                    Text(profile.memberSince)
                        .font(ClickTypography.microcopy)
                        .foregroundStyle(ClickColors.tertiaryLabel)
                }

                if !profile.bio.isEmpty {
                    Text(profile.bio)
                        .font(ClickTypography.bodySmall)
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func avatar(_ profile: UserProfileSnapshot) -> some View {
        if let raw = profile.avatarUrl,
           let url = URL(string: raw) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                avatarFallback(profile)
            }
        } else {
            avatarFallback(profile)
        }
    }

    private func avatarFallback(_ profile: UserProfileSnapshot) -> some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.58))
            .overlay {
                Text(profile.initials)
                    .font(ClickTypography.headlineSmall)
                    .foregroundStyle(ClickColors.primary)
            }
    }

    private func statsStrip(_ profile: UserProfileSnapshot) -> some View {
        HStack(spacing: 0) {
            ProfileStatColumn(title: "Clicks", count: profile.totalClicks)
            Divider().frame(height: 38)
            ProfileStatColumn(title: "Encounters", count: profile.totalEncounters)
            Divider().frame(height: 38)
            ProfileStatColumn(title: "Circles", count: profile.totalCircles)
        }
        .padding(.vertical, 14)
        .profileSurface()
    }

    private func tagSection(
        title: String,
        tags: [String],
        emphasized: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textPrimary)

            FlowLayout(spacing: 7) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(ClickTypography.labelMedium)
                        .foregroundStyle(
                            emphasized
                                ? ClickColors.primary
                                : ClickColors.textPrimary
                        )
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            emphasized
                                ? ClickColors.primaryFixed.opacity(0.58)
                                : ClickColors.surfaceContainerLow
                        )
                        .clipShape(Capsule())
                        .overlay {
                            Capsule()
                                .stroke(
                                    emphasized
                                        ? ClickColors.primary.opacity(0.2)
                                        : ClickColors.quietBorder.opacity(0.5),
                                    lineWidth: ClickSpacing.borderQuietWidth
                                )
                        }
                }
            }
        }
        .padding(14)
        .profileSurface()
    }

    private func timelineSection(_ entries: [ProfileTimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.top, 13)

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.body)
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if let authorName = entry.authorName, !authorName.isEmpty {
                            Text(authorName)
                        }

                        if entry.authorName?.isEmpty == false, entry.createdAt != nil {
                            Text("·")
                        }

                        if let createdAt = entry.createdAt {
                            Text(createdAt, style: .relative)
                        }
                    }
                    .font(ClickTypography.microcopy)
                    .foregroundStyle(ClickColors.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                if entry.id != entries.last?.id {
                    Divider()
                        .overlay(ClickColors.quietBorder.opacity(0.62))
                        .padding(.leading, 14)
                }
            }
            .padding(.bottom, 4)
        }
        .profileSurface()
    }

    private var accountActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account")
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textPrimary)

            Button(action: signOut) {
                HStack(spacing: 10) {
                    if isSigningOut {
                        ProgressView()
                            .controlSize(.small)
                            .tint(ClickColors.error)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                    }

                    Text("Sign Out")
                        .font(ClickTypography.bodyMedium)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClickColors.tertiaryLabel)
                }
                .foregroundStyle(ClickColors.error)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .contentShape(Rectangle())
                .profileSurface()
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(ClickColors.primary)
            Text("Loading profile…")
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cachedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))

            Text("Showing saved profile")
                .font(ClickTypography.captionSmall)

            Spacer()

            Button("Retry") {
                Task { await refresh() }
            }
            .font(ClickTypography.captionSmall)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .profileSurface()
    }

    @MainActor
    private func bootstrap() async {
        guard data == nil,
              let userID = resolvedUserID else {
            return
        }

        if let cached = await env.phase3.cachedProfile(for: userID) {
            data = cached
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard let userID = resolvedUserID else { return }

        do {
            data = if isSelf {
                try await env.phase3.refreshSelfProfile(userID: userID)
            } else {
                try await env.phase3.refreshProfile(
                    userID: userID,
                    connectionID: connectionID
                )
            }
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

private struct ProfileStatColumn: View {
    let title: String
    let count: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(ClickTypography.titleLarge)
                .foregroundStyle(ClickColors.textPrimary)
                .monospacedDigit()

            Text(title)
                .font(ClickTypography.microcopy)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }

            maxHeightInRow = max(maxHeightInRow, size.height)
            currentX += size.width + spacing
        }

        return CGSize(
            width: width,
            height: currentY + maxHeightInRow
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            maxHeightInRow = max(maxHeightInRow, size.height)
            currentX += size.width + spacing
        }
    }
}

private extension View {
    func profileSurface() -> some View {
        self
            .background(ClickColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ClickSpacing.radiusCard, style: .continuous)
                    .stroke(
                        ClickColors.quietBorder.opacity(0.72),
                        lineWidth: ClickSpacing.borderQuietWidth
                    )
            }
    }
}
