import SwiftUI

/// Pinned search pill on Home triggering quick search sheet.
public struct HomeSearchPill: View {
    let onTap: () -> Void

    public init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: {
            ClickHaptics.selection()
            onTap()
        }) {
            HStack(spacing: ClickSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.outline)

                Text("Search connections, places, circles…")
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textSecondary)

                Spacer()
            }
            .padding(.horizontal, ClickSpacing.md)
            .padding(.vertical, 12)
            .background(ClickColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
            .overlay(
                RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Pill chip representing an availability intent ("I'm down for…").
public struct AvailabilityIntentPill: View {
    let intent: AvailabilityIntent
    let onToggle: (() -> Void)?

    public init(intent: AvailabilityIntent, onToggle: (() -> Void)? = nil) {
        self.intent = intent
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: {
            guard let onToggle else { return }
            ClickHaptics.selection()
            onToggle()
        }) {
            HStack(spacing: ClickSpacing.xxs) {
                Text(intent.emoji)
                    .font(.system(size: 14))
                Text(intent.label)
                    .font(ClickTypography.labelMedium)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(intent.isSelected ? ClickColors.primary : ClickColors.surfaceContainerLow)
            .foregroundStyle(intent.isSelected ? ClickColors.onPrimary : ClickColors.textPrimary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(intent.isSelected ? ClickColors.primary : ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
            )
        }
        .buttonStyle(.plain)
        .disabled(onToggle == nil)
    }
}

/// Hero card for an upcoming featured event or beacon.
public struct FeaturedEventCard: View {
    let event: HomeFeaturedEvent
    let onTap: () -> Void

    public init(event: HomeFeaturedEvent, onTap: @escaping () -> Void) {
        self.event = event
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: {
            ClickHaptics.impact(.light)
            onTap()
        }) {
            VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                HStack {
                    Text(event.category.uppercased())
                        .font(ClickTypography.labelSmall)
                        .fontWeight(.bold)
                        .foregroundStyle(ClickColors.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ClickColors.primaryFixed.opacity(0.35))
                        .clipShape(Capsule())

                    Spacer()

                    HStack(spacing: ClickSpacing.xxs) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11))
                        Text("\(event.attendeeCount) going")
                            .font(ClickTypography.labelSmall)
                    }
                    .foregroundStyle(ClickColors.textSecondary)
                }

                Text(event.title)
                    .font(ClickTypography.titleMedium)
                    .fontWeight(.bold)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.leading)

                HStack(spacing: ClickSpacing.md) {
                    HStack(spacing: ClickSpacing.xxs) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12))
                        Text(event.timeDescription)
                            .font(ClickTypography.bodySmall)
                    }

                    HStack(spacing: ClickSpacing.xxs) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 12))
                        Text(event.locationName)
                            .font(ClickTypography.bodySmall)
                    }
                }
                .foregroundStyle(ClickColors.textSecondary)
            }
            .padding(ClickSpacing.md)
            .background(ClickColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Compact beacon discovery tile.
public struct ExploreBeaconTile: View {
    let beacon: ExploreBeaconItem
    let onTap: () -> Void

    public init(beacon: ExploreBeaconItem, onTap: @escaping () -> Void) {
        self.beacon = beacon
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: {
            ClickHaptics.selection()
            onTap()
        }) {
            HStack(spacing: ClickSpacing.md) {
                ZStack {
                    Circle()
                        .fill(ClickColors.primaryFixed.opacity(0.35))
                        .frame(width: 42, height: 42)
                    Image(systemName: beacon.iconName)
                        .font(.system(size: 18))
                        .foregroundStyle(ClickColors.primary)
                }

                VStack(alignment: .leading, spacing: ClickSpacing.xxxSmall) {
                    Text(beacon.title)
                        .font(ClickTypography.titleSmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(ClickColors.textPrimary)

                    Text(beacon.subtitle)
                        .font(ClickTypography.bodySmall)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: ClickSpacing.xxxSmall) {
                    Text(beacon.distanceFormatted)
                        .font(ClickTypography.labelMedium)
                        .fontWeight(.bold)
                        .foregroundStyle(ClickColors.primary)

                    Text("\(beacon.memberCount) here")
                        .font(ClickTypography.labelSmall)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
            .padding(ClickSpacing.md)
            .background(ClickColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Row item representing a recent connection with presence dot.
public struct RecentConnectionRowItem: View {
    let connection: RecentConnectionSummary
    let onTap: () -> Void

    public init(connection: RecentConnectionSummary, onTap: @escaping () -> Void) {
        self.connection = connection
        self.onTap = onTap
    }

    private var avatarFallback: some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.4))
            .overlay(
                Text(connection.initials)
                    .font(ClickTypography.titleSmall)
                    .fontWeight(.bold)
                    .foregroundStyle(ClickColors.primary)
            )
    }

    public var body: some View {
        Button(action: {
            ClickHaptics.selection()
            onTap()
        }) {
            HStack(spacing: ClickSpacing.md) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let raw = connection.avatarUrl, let url = URL(string: raw) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                avatarFallback
                            }
                        } else {
                            avatarFallback
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())

                    if connection.presenceKnown {
                        Circle()
                            .fill(connection.isOnline ? Color(hex: "#10B981") : ClickColors.outline.opacity(0.4))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(ClickColors.background, lineWidth: 2))
                    }
                }

                VStack(alignment: .leading, spacing: ClickSpacing.xxxSmall) {
                    HStack(spacing: ClickSpacing.xs) {
                        Text(connection.displayName)
                            .font(ClickTypography.titleSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ClickColors.textPrimary)

                        Text(connection.handle)
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textSecondary)
                    }

                    HStack(spacing: ClickSpacing.xxs) {
                        Image(systemName: "mappin")
                            .font(.system(size: 11))
                        Text(connection.encounterLocation)
                            .font(ClickTypography.bodySmall)
                    }
                    .foregroundStyle(ClickColors.textSecondary)
                }

                Spacer()

                Text(connection.lastActiveRelative)
                    .font(ClickTypography.labelSmall)
                    .foregroundStyle(connection.isOnline ? ClickColors.primary : ClickColors.textSecondary)
            }
            .padding(.vertical, ClickSpacing.xs)
        }
        .buttonStyle(.plain)
    }
}

/// Metric counter card for Home tab stats.
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
        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
            HStack {
                Text("\(value)")
                    .font(.custom("Manrope-ExtraBold", size: 28))
                    .foregroundStyle(ClickColors.textPrimary)
                Spacer()
                Image(systemName: iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(ClickColors.primary)
            }

            Text(title)
                .font(ClickTypography.labelMedium)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .padding(ClickSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
        )
    }
}
