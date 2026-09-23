import SwiftUI

public struct HomeSearchPill: View {
    let onTap: () -> Void

    public init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    public var body: some View {
        Button {
            ClickHaptics.selection()
            onTap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ClickColors.textSecondary)

                Text("Search people, places, events…")
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.searchMinHeight)
            .background(ClickColors.fillSubtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

public struct AvailabilityIntentPill: View {
    let intent: AvailabilityIntent
    let onToggle: (() -> Void)?

    public init(intent: AvailabilityIntent, onToggle: (() -> Void)? = nil) {
        self.intent = intent
        self.onToggle = onToggle
    }

    public var body: some View {
        Button {
            guard let onToggle else { return }
            ClickHaptics.selection()
            onToggle()
        } label: {
            HStack(spacing: 6) {
                Text(intent.emoji)
                    .font(.system(size: 14))

                Text(intent.label)
                    .font(ClickTypography.supportingEmphasized)
            }
            .padding(.horizontal, 13)
            .frame(minHeight: ClickMetrics.chipHeight)
            .background(
                intent.isSelected
                    ? ClickColors.selectionTint
                    : ClickColors.surface
            )
            .foregroundStyle(
                intent.isSelected
                    ? ClickColors.accentForeground
                    : ClickColors.textPrimary
            )
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        intent.isSelected
                            ? ClickColors.accentForeground.opacity(0.38)
                            : ClickColors.separator,
                        lineWidth: ClickMetrics.strokeWidth
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(onToggle == nil)
    }
}

public struct FeaturedEventCard: View {
    let event: HomeFeaturedEvent
    let onTap: () -> Void

    public init(event: HomeFeaturedEvent, onTap: @escaping () -> Void) {
        self.event = event
        self.onTap = onTap
    }

    public var body: some View {
        Button {
            ClickHaptics.impact(.light)
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(event.category.uppercased())
                        .font(ClickTypography.caption)
                        .foregroundStyle(ClickColors.accentForeground)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(ClickColors.selectionTint)
                        .clipShape(Capsule())

                    Spacer()

                    Label("\(event.attendeeCount) going", systemImage: "person.2.fill")
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                Text(event.title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Label(event.timeDescription, systemImage: "clock")
                    Label(event.locationName, systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                }
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClickColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous)
                    .stroke(
                        ClickColors.separator.opacity(0.72),
                        lineWidth: ClickMetrics.strokeWidth
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

public struct ExploreBeaconTile: View {
    let beacon: ExploreBeaconItem
    let onTap: () -> Void

    public init(beacon: ExploreBeaconItem, onTap: @escaping () -> Void) {
        self.beacon = beacon
        self.onTap = onTap
    }

    public var body: some View {
        Button {
            ClickHaptics.selection()
            onTap()
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(ClickColors.selectionTint)
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: beacon.iconName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(ClickColors.accentForeground)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(beacon.title)
                        .font(ClickTypography.body)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)

                    Text(beacon.subtitle)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(beacon.distanceFormatted)
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.accentForeground)

                    Text("\(beacon.memberCount) here")
                        .font(ClickTypography.caption)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClickColors.textTertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct RecentConnectionRowItem: View {
    let connection: RecentConnectionSummary
    let onTap: () -> Void

    public init(connection: RecentConnectionSummary, onTap: @escaping () -> Void) {
        self.connection = connection
        self.onTap = onTap
    }

    public var body: some View {
        Button {
            ClickHaptics.selection()
            onTap()
        } label: {
            HStack(spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(connection.displayName)
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)

                        if !connection.handle.isEmpty {
                            Text(connection.handle)
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    if !connection.encounterLocation.isEmpty {
                        Label(connection.encounterLocation, systemImage: "mappin")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(connection.lastActiveRelative)
                    .font(ClickTypography.caption)
                    .foregroundStyle(
                        connection.isOnline
                            ? ClickColors.accentForeground
                            : ClickColors.textSecondary
                    )
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        AvatarView(
            imageURL: connection.avatarUrl,
            seed: connection.userID,
            initials: connection.initials,
            size: ClickMetrics.Avatar.row,
            presence: AvatarView.Presence(isOnline: connection.isOnline, known: connection.presenceKnown)
        )
    }
}

public struct HomeStatCard: View {
    let title: String
    let value: Int
    let iconName: String

    public init(title: String, value: Int, iconName: String) {
        self.title = title
        self.value = value
        self.iconName = iconName
    }

    public var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Text("\(value)")
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .monospacedDigit()

                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClickColors.accentForeground)
            }

            Text(title)
                .font(ClickTypography.caption)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
