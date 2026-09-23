import SwiftUI

/// Phase 3 native profile surface backed by authenticated profile + timeline APIs.
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
        guard let resolvedUserID, let current = env.session.currentSession?.userId else { return false }
        return resolvedUserID == current
    }

    public var body: some View {
        Group {
            if let data {
                ScrollView {
                    VStack(spacing: ClickSpacing.lg) {
                        if refreshError != nil {
                            HStack(spacing: ClickSpacing.xs) {
                                Image(systemName: "wifi.exclamationmark")
                                Text("Showing the last saved profile")
                                Spacer()
                                Button("Retry") { Task { await refresh() } }
                            }
                            .font(ClickTypography.labelMedium)
                            .foregroundStyle(ClickColors.textSecondary)
                        }

                        profileHeader(data.profile)

                        if isSelf {
                            statsStrip(data.profile)
                        }

                        if !data.profile.interests.isEmpty {
                            tagSection(title: "Interests", tags: data.profile.interests, emphasized: true)
                        }

                        if !data.profile.personalityTraits.isEmpty {
                            tagSection(title: "Personality Traits", tags: data.profile.personalityTraits, emphasized: false)
                        }

                        if !data.timeline.isEmpty {
                            timelineSection(data.timeline)
                        }

                        if isSelf {
                            Button(action: signOut) {
                                HStack(spacing: ClickSpacing.xs) {
                                    if isSigningOut {
                                        ProgressView().tint(ClickColors.error)
                                    } else {
                                        Image(systemName: "rectangle.portrait.and.arrow.right")
                                        Text("Sign Out")
                                    }
                                }
                                .font(ClickTypography.labelLarge)
                                .foregroundStyle(ClickColors.error)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(ClickColors.error.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                            }
                            .disabled(isSigningOut)
                        }
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.bottom, ClickSpacing.xxl)
                }
                .refreshable { await refresh() }
            } else {
                VStack(spacing: ClickSpacing.md) {
                    ProgressView()
                    Text("Loading profile…")
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle(isSelf ? "Me" : (data?.profile.displayName ?? "Profile"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await bootstrap() }
    }

    private func profileHeader(_ profile: UserProfileSnapshot) -> some View {
        VStack(spacing: ClickSpacing.md) {
            Group {
                if let raw = profile.avatarUrl, let url = URL(string: raw) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        avatarFallback(profile)
                    }
                } else {
                    avatarFallback(profile)
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(Circle())
            .overlay(Circle().stroke(ClickColors.primary, lineWidth: 2))

            VStack(spacing: ClickSpacing.xxs) {
                Text(profile.displayName)
                    .font(ClickTypography.headlineSmall)
                    .fontWeight(.bold)
                    .foregroundStyle(ClickColors.textPrimary)

                if !profile.handle.isEmpty {
                    Text(profile.handle)
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                if !profile.memberSince.isEmpty {
                    Text(profile.memberSince)
                        .font(ClickTypography.labelSmall)
                        .foregroundStyle(ClickColors.outline)
                }
            }

            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(ClickTypography.bodySmall)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, ClickSpacing.sm)
    }

    private func avatarFallback(_ profile: UserProfileSnapshot) -> some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.4))
            .overlay(
                Text(profile.initials)
                    .font(.custom("Manrope-ExtraBold", size: 34))
                    .foregroundStyle(ClickColors.primary)
            )
    }

    private func statsStrip(_ profile: UserProfileSnapshot) -> some View {
        HStack(spacing: ClickSpacing.sm) {
            ProfileStatColumn(title: "Clicks", count: profile.totalClicks)
            Divider().frame(height: 32)
            ProfileStatColumn(title: "Encounters", count: profile.totalEncounters)
            Divider().frame(height: 32)
            ProfileStatColumn(title: "Circles", count: profile.totalCircles)
        }
        .padding(.vertical, ClickSpacing.md)
        .frame(maxWidth: .infinity)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
    }

    private func tagSection(title: String, tags: [String], emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: ClickSpacing.sm) {
            Text(title)
                .font(ClickTypography.titleSmall)
                .fontWeight(.semibold)
                .foregroundStyle(ClickColors.textPrimary)

            FlowLayout(spacing: ClickSpacing.xs) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(ClickTypography.labelMedium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            emphasized
                                ? ClickColors.primaryFixed.opacity(0.35)
                                : ClickColors.surfaceContainerHigh
                        )
                        .foregroundStyle(emphasized ? ClickColors.primary : ClickColors.textPrimary)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(ClickSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
    }

    private func timelineSection(_ entries: [ProfileTimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: ClickSpacing.sm) {
            Text("Timeline")
                .font(ClickTypography.titleSmall)
                .fontWeight(.semibold)
                .foregroundStyle(ClickColors.textPrimary)

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: ClickSpacing.xxs) {
                    Text(entry.body)
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textPrimary)

                    HStack {
                        if let authorName = entry.authorName, !authorName.isEmpty {
                            Text(authorName)
                        }
                        if let createdAt = entry.createdAt {
                            Text(createdAt, style: .relative)
                        }
                    }
                    .font(ClickTypography.labelSmall)
                    .foregroundStyle(ClickColors.textSecondary)
                }
                .padding(.vertical, ClickSpacing.xs)

                if entry.id != entries.last?.id {
                    Divider().background(ClickColors.quietBorder)
                }
            }
        }
        .padding(ClickSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
    }

    @MainActor
    private func bootstrap() async {
        guard data == nil, let userID = resolvedUserID else { return }
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
                try await env.phase3.refreshProfile(userID: userID, connectionID: connectionID)
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
        VStack(spacing: ClickSpacing.xxxSmall) {
            Text("\(count)")
                .font(.custom("Manrope-ExtraBold", size: 20))
                .foregroundStyle(ClickColors.textPrimary)
            Text(title)
                .font(ClickTypography.labelSmall)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
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
        return CGSize(width: width, height: currentY + maxHeightInRow)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            maxHeightInRow = max(maxHeightInRow, size.height)
            currentX += size.width + spacing
        }
    }
}
