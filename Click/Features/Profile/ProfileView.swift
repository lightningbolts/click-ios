import SwiftUI

/// Phase 3 native User Profile screen ("Me" tab).
public struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var profile: UserProfileSnapshot
    @State private var isSigningOut: Bool = false

    public init(initialProfile: UserProfileSnapshot = .preview) {
        self._profile = State(initialValue: initialProfile)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: ClickSpacing.lg) {
                // Header Profile Hero Card
                VStack(spacing: ClickSpacing.md) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(ClickColors.primaryFixed.opacity(0.4))
                            .frame(width: 88, height: 88)
                            .overlay(
                                Text(profile.initials)
                                    .font(.custom("Manrope-ExtraBold", size: 34))
                                    .foregroundStyle(ClickColors.primary)
                            )
                            .overlay(
                                Circle()
                                    .stroke(ClickColors.primary, lineWidth: 2)
                            )
                    }

                    VStack(spacing: ClickSpacing.xxs) {
                        Text(profile.displayName)
                            .font(ClickTypography.headlineSmall)
                            .fontWeight(.bold)
                            .foregroundStyle(ClickColors.textPrimary)

                        Text(profile.handle)
                            .font(ClickTypography.bodyMedium)
                            .foregroundStyle(ClickColors.textSecondary)

                        Text(profile.memberSince)
                            .font(ClickTypography.labelSmall)
                            .foregroundStyle(ClickColors.outline)
                            .padding(.top, ClickSpacing.xxs)
                    }

                    // Bio Card
                    if !profile.bio.isEmpty {
                        Text(profile.bio)
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ClickSpacing.md)
                            .padding(.vertical, ClickSpacing.sm)
                            .background(ClickColors.surfaceContainerLow)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                            )
                    }
                }
                .padding(.top, ClickSpacing.sm)

                // Stats Metrics Strip
                HStack(spacing: ClickSpacing.sm) {
                    ProfileStatColumn(title: "Clicks", count: profile.totalClicks)
                    Divider()
                        .frame(height: 32)
                        .background(ClickColors.quietBorder)
                    ProfileStatColumn(title: "Encounters", count: profile.totalEncounters)
                    Divider()
                        .frame(height: 32)
                        .background(ClickColors.quietBorder)
                    ProfileStatColumn(title: "Circles", count: profile.totalCircles)
                }
                .padding(.vertical, ClickSpacing.md)
                .frame(maxWidth: .infinity)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                )

                // My Interests Section
                VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                    HStack {
                        Text("My Interests")
                            .font(ClickTypography.titleSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ClickColors.textPrimary)
                        Spacer()
                        Text("\(profile.interests.count)")
                            .font(ClickTypography.labelSmall)
                            .foregroundStyle(ClickColors.primary)
                    }

                    FlowLayout(spacing: ClickSpacing.xs) {
                        ForEach(profile.interests, id: \.self) { interest in
                            Text(interest)
                                .font(ClickTypography.labelMedium)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(ClickColors.primaryFixed.opacity(0.35))
                                .foregroundStyle(ClickColors.primary)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(ClickSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                )

                // My Personality Section
                VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                    HStack {
                        Text("Personality Traits")
                            .font(ClickTypography.titleSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ClickColors.textPrimary)
                        Spacer()
                        Text("\(profile.personalityTraits.count)")
                            .font(ClickTypography.labelSmall)
                            .foregroundStyle(ClickColors.primary)
                    }

                    FlowLayout(spacing: ClickSpacing.xs) {
                        ForEach(profile.personalityTraits, id: \.self) { trait in
                            Text(trait)
                                .font(ClickTypography.labelMedium)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(ClickColors.surfaceContainerHigh)
                                .foregroundStyle(ClickColors.textPrimary)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(ClickSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                )

                // Settings & Preferences Rows
                VStack(spacing: 0) {
                    ProfileSettingsRow(icon: "paintbrush.fill", title: "Appearance")
                    Divider().background(ClickColors.quietBorder).padding(.leading, 52)
                    ProfileSettingsRow(icon: "lock.shield.fill", title: "Privacy & Security")
                    Divider().background(ClickColors.quietBorder).padding(.leading, 52)
                    ProfileSettingsRow(icon: "bell.fill", title: "Notifications")
                    Divider().background(ClickColors.quietBorder).padding(.leading, 52)
                    ProfileSettingsRow(icon: "person.crop.circle.badge.questionmark", title: "Help & Support")
                }
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                )

                // Sign Out Button
                Button(action: signOut) {
                    HStack(spacing: ClickSpacing.xs) {
                        if isSigningOut {
                            ProgressView()
                                .tint(ClickColors.error)
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
                .padding(.top, ClickSpacing.xs)
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.bottom, ClickSpacing.xxl)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Me")
        .navigationBarTitleDisplayMode(.inline)
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

/// Stat column in profile hero card.
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

/// Row item in settings card.
private struct ProfileSettingsRow: View {
    let icon: String
    let title: String

    var body: some View {
        Button(action: {
            ClickHaptics.selection()
        }) {
            HStack(spacing: ClickSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(ClickColors.primary)
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClickColors.outline)
            }
            .padding(.horizontal, ClickSpacing.md)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

/// Flow layout for tags in profile.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
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
        height = currentY + maxHeightInRow
        return CGSize(width: width, height: height)
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
