import SwiftUI

// Home-local building blocks. Rows live inside one grouped surface per section; they are not
// independent cards (spec §20.2: "avoid equal-weight bordered dashboard cards").

/// Uppercase grouped-list caption (e.g. "I'M DOWN FOR…").
struct HomeCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(ClickTypography.metadata)
            .foregroundStyle(ClickColors.textTertiary)
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Manrope section headline.
struct HomeSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ClickTypography.sectionTitle)
            .foregroundStyle(ClickColors.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A grouped-list row: fixed leading slot, stacked content, optional trailing accessory.
struct HomeRow<Leading: View, Content: View>: View {
    let inset: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 14) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(minHeight: ClickMetrics.rowMinHeight + 6)
        .contentShape(Rectangle())
    }
}

/// Hairline separator inset to the row text.
struct HomeDivider: View {
    let inset: CGFloat

    var body: some View {
        Rectangle()
            .fill(ClickColors.separator)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

struct HomeLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(minHeight: ClickMetrics.rowMinHeight)
        .accessibilityLabel("Loading")
    }
}

/// A failed module with no cached data: states the failure and offers retry. Never "empty".
struct HomeRetryRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(ClickColors.textTertiary)
            Text(message)
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: ClickMetrics.rowMinHeight)
    }
}

/// A confirmed-empty module (successful response) with one quiet next step.
struct HomeEmptyRow: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: ClickMetrics.rowMinHeight)
    }
}

// MARK: - Opportunity

/// The one promoted social opportunity. Exactly one filled action per module.
struct HomeOpportunitySection: View {
    let opportunity: HomeOpportunity
    let person: ConnectionItem?
    let onOpenEvent: (String) -> Void
    let onShowOnMap: (String) -> Void
    let onMessage: (HomeMessageTarget) -> Void
    let onResolveNudge: (InboxNudge, MeRepository.NudgeAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionTitle(title)
                .padding(.horizontal, 4)
            content
                .groupedSurface()
        }
    }

    private var title: String {
        switch opportunity {
        case .event(let event): event.isLive ? "Happening now" : "Today"
        case .nudge(let nudge): nudge.kind == .sharedUpcomingEvent ? "Going together" : "Reconnect"
        case .sayHi: "Say hi"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch opportunity {
        case .event(let event):
            eventHero(event)
        case .nudge(let nudge):
            HomeNudgeRow(
                nudge: nudge,
                person: person,
                onMessage: { onMessage(.nudge(nudge)) },
                onDismiss: { onResolveNudge(nudge, .dismiss) }
            )
            .padding(18)
        case .sayHi(let item, let deadline):
            sayHi(item, deadline: deadline)
        }
    }

    private func eventHero(_ event: HomeEventHighlight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onOpenEvent(event.id) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    EventVisual(seed: event.id, imageURL: event.imageURL, cornerRadius: 0)
                        .frame(height: 148)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(alignment: .topLeading) {
                            StatusPill(event.isLive ? "Live now" : "Today", style: event.isLive ? .live : .neutral)
                                .padding(14)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(ClickColors.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(EventFormatting.whenAndWhere(event.schedule, place: event.place))
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textTertiary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens event details")

            HStack(spacing: 10) {
                Button("View details") { onOpenEvent(event.id) }
                    .buttonStyle(.clickPrimary)
                Button {
                    onShowOnMap(event.id)
                } label: {
                    Label("Map", systemImage: "map")
                }
                .buttonStyle(.clickSecondary)
                .frame(maxWidth: 110)
            }
            .padding(18)
        }
    }

    private func sayHi(_ item: ConnectionItem, deadline: Date) -> some View {
        HStack(spacing: 12) {
            AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Say hi to \(HomeFeedModel.firstName(item.displayName) ?? item.displayName)")
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(InboxFormatting.sayHiRemaining(until: deadline).map { "\($0) before this Click is archived" }
                     ?? "Before this Click is archived")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            }
            Spacer(minLength: 8)
            Button("Say hi") { onMessage(.connection(item)) }
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(ClickColors.selectionTint, in: Capsule())
                .frame(minHeight: ClickMetrics.minimumHitTarget)
        }
        .padding(18)
    }
}

/// A relationship nudge row: person, server copy, "Say hi", dismiss.
struct HomeNudgeRow: View {
    let nudge: InboxNudge
    let person: ConnectionItem?
    let onMessage: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let person {
                AvatarView(imageURL: person.avatarUrl, seed: person.userID, initials: person.initials, size: 44)
            } else {
                Image(systemName: nudge.kind == .sharedUpcomingEvent ? "calendar" : "hand.wave.fill")
                    .foregroundStyle(ClickColors.accentForeground)
                    .frame(width: 44, height: 44)
                    .background(ClickColors.selectionTint, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(nudge.headline)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                if !nudge.body.isEmpty {
                    Text(nudge.body)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Say hi", action: onMessage)
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(ClickColors.selectionTint, in: Capsule())
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClickColors.textTertiary)
                    .frame(width: 30, height: ClickMetrics.minimumHitTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }
}

// MARK: - Saved events, discovery, insights

struct SavedEventRow: View {
    let event: SavedEvent

    var body: some View {
        HStack(spacing: 14) {
            EventVisual(seed: event.beaconID, symbol: "calendar")
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Unavailable event")
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(1)
                if let schedule = event.schedule {
                    Text(EventFormatting.whenAndWhere(schedule, place: event.placeLabel))
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                        .lineLimit(1)
                } else if let place = event.placeLabel {
                    Text(place)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let status = EventFormatting.status(event.schedule) {
                Text(status.text)
                    .font(ClickTypography.metadataEmphasized)
                    .foregroundStyle(status.isLive ? ClickColors.destructive : ClickColors.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DiscoveryChip: View {
    let title: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(count, format: .number)
                    .foregroundStyle(ClickColors.textTertiary)
                    .monospacedDigit()
            }
            .font(ClickTypography.supporting.weight(.medium))
            .padding(.horizontal, 15)
            .frame(minHeight: ClickMetrics.chipHeight)
            .background(ClickColors.fillSubtle, in: Capsule())
            .frame(minHeight: ClickMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(title) nearby")
    }
}

struct InsightTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title.weight(.bold))
                .foregroundStyle(ClickColors.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: ClickRadius.surface - 4, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
