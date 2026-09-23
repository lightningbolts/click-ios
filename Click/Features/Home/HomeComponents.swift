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
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(ClickColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ClickSpacing.radiusInput, style: .continuous)
                    .stroke(
                        ClickColors.quietBorder.opacity(0.78),
                        lineWidth: ClickSpacing.borderQuietWidth
                    )
            }
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
                    .font(ClickTypography.labelMedium)
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(
                intent.isSelected
                    ? ClickColors.primaryFixed.opacity(0.72)
                    : ClickColors.surface
            )
            .foregroundStyle(
                intent.isSelected
                    ? ClickColors.primary
                    : ClickColors.textPrimary
            )
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        intent.isSelected
                            ? ClickColors.primary.opacity(0.38)
                            : ClickColors.quietBorder.opacity(0.78),
                        lineWidth: ClickSpacing.borderQuietWidth
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
                        .font(ClickTypography.microcopy)
                        .foregroundStyle(ClickColors.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(ClickColors.primaryFixed.opacity(0.64))
                        .clipShape(Capsule())

                    Spacer()

                    Label("\(event.attendeeCount) going", systemImage: "person.2.fill")
                        .font(ClickTypography.captionSmall)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                Text(event.title)
                    .font(ClickTypography.titleMedium)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Label(event.timeDescription, systemImage: "clock")
                    Label(event.locationName, systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                }
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .fill(ClickColors.primaryFixed.opacity(0.56))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: beacon.iconName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(ClickColors.primary)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(beacon.title)
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)

                    Text(beacon.subtitle)
                        .font(ClickTypography.bodySmall)
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(beacon.distanceFormatted)
                        .font(ClickTypography.captionSmall)
                        .foregroundStyle(ClickColors.primary)

                    Text("\(beacon.memberCount) here")
                        .font(ClickTypography.microcopy)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClickColors.tertiaryLabel)
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
                            .font(ClickTypography.bodyMedium)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)

                        if !connection.handle.isEmpty {
                            Text(connection.handle)
                                .font(ClickTypography.bodySmall)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    if !connection.encounterLocation.isEmpty {
                        Label(connection.encounterLocation, systemImage: "mappin")
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(connection.lastActiveRelative)
                    .font(ClickTypography.microcopy)
                    .foregroundStyle(
                        connection.isOnline
                            ? ClickColors.primary
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
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let raw = connection.avatarUrl,
                   let url = URL(string: raw) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        fallbackAvatar
                    }
                } else {
                    fallbackAvatar
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            if connection.presenceKnown {
                Circle()
                    .fill(
                        connection.isOnline
                            ? ClickColors.statusOnline
                            : ClickColors.statusOffline
                    )
                    .frame(width: 11, height: 11)
                    .overlay {
                        Circle()
                            .stroke(ClickColors.surface, lineWidth: 2)
                    }
            }
        }
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.5))
            .overlay {
                Text(connection.initials)
                    .font(ClickTypography.labelMedium)
                    .foregroundStyle(ClickColors.primary)
            }
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
                    .font(ClickTypography.titleLarge)
                    .foregroundStyle(ClickColors.textPrimary)
                    .monospacedDigit()

                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClickColors.primary)
            }

            Text(title)
                .font(ClickTypography.microcopy)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
