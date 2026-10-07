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
            ClickLoadingView(size: 26, fillsSpace: false)
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
    let onNudgeAction: (InboxNudge) -> Void
    let onDeclineHangout: (InboxNudge) -> Void
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
        case .nudge(let nudge): nudge.sectionTitle
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
                onPrimary: { onNudgeAction(nudge) },
                onDecline: { onDeclineHangout(nudge) },
                onDismiss: { onResolveNudge(nudge, .dismiss) }
            )
            .padding(18)
        case .sayHi(let item, let deadline):
            sayHi(item, deadline: deadline)
        }
    }

    private func eventHero(_ event: HomeEventHighlight) -> some View {
        HomeEventCard(
            beaconID: event.id,
            imageURL: event.imageURL,
            pill: StatusPill(event.isLive ? "Live now" : "Today", style: event.isLive ? .live : .neutral),
            title: event.title,
            detail: EventFormatting.whenAndWhere(event.schedule, place: event.place),
            onOpen: { onOpenEvent(event.id) },
            onShowOnMap: { onShowOnMap(event.id) }
        )
    }

    private func sayHi(_ item: ConnectionItem, deadline: Date) -> some View {
        HStack(spacing: 12) {
            AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: 44, isCore: item.isCore)
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

extension InboxNudge {
    /// Home section heading for this kind.
    var sectionTitle: String {
        switch kind {
        case .sharedUpcomingEvent: "Going together"
        case .reconnectLull: "Reconnect"
        case .anniversary: "Anniversary"
        case .memoryPrompt: "Memories"
        case .groupRevival: "Your groups"
        case .wave: "Wave"
        case .hangoutConfirm: "Hanging out?"
        }
    }

    /// The one filled action.
    var actionTitle: String {
        switch kind {
        case .sharedUpcomingEvent, .reconnectLull, .anniversary: "Say hi"
        case .memoryPrompt: "Add memory"
        case .groupRevival: "Plan"
        case .wave: "Wave back"
        case .hangoutConfirm: "Confirm"
        }
    }

    var symbol: String {
        switch kind {
        case .sharedUpcomingEvent: "calendar"
        case .anniversary: "gift.fill"
        case .memoryPrompt: "photo.on.rectangle.angled"
        case .groupRevival: "person.3.fill"
        case .hangoutConfirm: "figure.2"
        case .reconnectLull, .wave: "hand.wave.fill"
        }
    }
}

/// A relationship nudge: person, server copy, the kind's action, and "Not now" (or "Not us" for a
/// hangout to confirm).
struct HomeNudgeRow: View {
    let nudge: InboxNudge
    let person: ConnectionItem?
    let onPrimary: () -> Void
    var onDecline: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        let isHangout = nudge.kind == .hangoutConfirm
        HomePersonPrompt(
            title: nudge.headline,
            detail: nudge.body.nonEmptyTrimmed,
            primaryTitle: nudge.actionTitle,
            onPrimary: onPrimary,
            secondaryTitle: isHangout ? "Not us" : "Not now",
            secondaryHint: isHangout ? "You weren't together; nothing is logged" : nil,
            onSecondary: isHangout ? onDecline ?? onDismiss : onDismiss
        ) {
            if let person {
                AvatarView(imageURL: person.avatarUrl, seed: person.userID, initials: person.initials,
                           size: ClickMetrics.Avatar.row, isCore: person.isCore)
                    .overlay(alignment: .bottomTrailing) {
                        if nudge.kind != .reconnectLull {
                            Image(systemName: nudge.symbol)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(ClickColors.accentForeground)
                                .frame(width: 20, height: 20)
                                .background(ClickColors.surface, in: Circle())
                                .offset(x: 3, y: 3)
                                .accessibilityHidden(true)
                        }
                    }
            } else {
                Image(systemName: nudge.symbol)
                    .foregroundStyle(ClickColors.accentForeground)
                    .frame(width: ClickMetrics.Avatar.row, height: ClickMetrics.Avatar.row)
                    .background(ClickColors.selectionTint, in: Circle())
            }
        }
    }
}

/// A prompt about one person on Home (a nudge, a reconnect pick): who and why on top, then its
/// action and a quiet way out side by side, so the copy never wraps around the buttons.
struct HomePersonPrompt<Avatar: View>: View {
    let title: String
    let detail: String?
    let primaryTitle: String
    let onPrimary: () -> Void
    let secondaryTitle: String
    var secondaryHint: String? = nil
    let onSecondary: () -> Void
    /// Tapping who it's about (their profile); nil when it isn't a link.
    var onOpen: (() -> Void)? = nil
    @ViewBuilder let avatar: Avatar

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let onOpen {
                Button(action: onOpen) { identity }
                    .buttonStyle(.plain)
            } else {
                identity
                    .accessibilityElement(children: .combine)
            }
            HStack(spacing: 10) {
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .font(ClickTypography.supportingEmphasized)
                        .foregroundStyle(ClickColors.accentForeground)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(ClickColors.selectionTint, in: Capsule())
                }
                Button(action: onSecondary) {
                    Text(secondaryTitle)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(ClickColors.fillSubtle, in: Capsule())
                }
                .accessibilityHint(secondaryHint ?? "")
            }
            .buttonStyle(.plain)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Saved events, discovery, insights

struct SavedEventRow: View {
    let event: SavedEvent

    var body: some View {
        HStack(spacing: 14) {
            BeaconVisual(beaconID: event.beaconID)
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

/// One of your upcoming events: its picture, when and where, and whether you're hosting, going
/// or saved it.
struct UpcomingEventRow: View {
    let event: HomeUpcomingEvent

    var body: some View {
        let status = EventFormatting.status(event.schedule)
        HStack(spacing: 14) {
            BeaconVisual(beaconID: event.id, imageURL: event.imageURL)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(1)
                Text(EventFormatting.whenAndWhere(event.schedule, place: event.place))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(status?.isLive == true ? ClickColors.destructive : ClickColors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(event.role.label)
                .font(ClickTypography.metadataEmphasized)
                .foregroundStyle(event.role == .saved ? ClickColors.textSecondary : ClickColors.accentForeground)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(event.role == .saved ? ClickColors.fillSubtle : ClickColors.selectionTint, in: Capsule())
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// An event as Home features it (Happening now, Recommended for you): its picture with one pill,
/// what, when and where, then View details and Map. The caller supplies the surface; given more
/// height than it needs (a row of cards), the buttons stay at the bottom.
struct HomeEventCard: View {
    let beaconID: String
    let imageURL: String?
    let pill: StatusPill
    let title: String
    let detail: String
    let onOpen: () -> Void
    let onShowOnMap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    BeaconVisual(beaconID: beaconID, imageURL: imageURL, symbol: nil, cornerRadius: 0)
                        .frame(height: 148)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(alignment: .topLeading) { pill.padding(14) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(ClickColors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        // Each "·" keeps to the line it follows, so a wrapped line never starts with one.
                        Text(detail.replacingOccurrences(of: " · ", with: "\u{00A0}· "))
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

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("View details", action: onOpen)
                    .buttonStyle(.clickPrimary)
                Button(action: onShowOnMap) {
                    // Matches View details beside it (secondary buttons are shorter by default).
                    Label("Map", systemImage: "map")
                        .frame(minHeight: ClickMetrics.primaryActionHeight)
                }
                .buttonStyle(.clickSecondary)
                .frame(maxWidth: 110)
            }
            .padding(18)
        }
    }
}

/// Up to three items' pictures, overlapping, each cut out of the surface behind it.
struct MapItemFacePile: View {
    let items: [MapItem]
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: -size * 0.36) {
            ForEach(items.prefix(3)) { item in
                MapItemThumbnail(item: item, size: size, cornerRadius: size / 2)
                    .clipShape(Circle())
                    .padding(1.5)
                    .background(ClickColors.background, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

struct DiscoveryChip: View {
    let title: String
    let count: Int
    /// A few of what's counted, shown as overlapping pictures before the title.
    var faces: [MapItem] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !faces.isEmpty {
                    MapItemFacePile(items: faces)
                }
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(ClickColors.textPrimary)
                    Text(count, format: .number)
                        .foregroundStyle(ClickColors.textTertiary)
                        .monospacedDigit()
                }
            }
            .font(ClickTypography.supporting.weight(.medium))
            .padding(.leading, faces.isEmpty ? 15 : 6)
            .padding(.trailing, 15)
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

/// Local "reconnect" pick when the server has no reconnect nudge: the Click you haven't talked
/// with the longest (14+ days), Core first. "Not now" hides that person for a week.
enum ReconnectSuggestion {
    private static let key = "home.reconnect.snoozed"
    static let quietDays: Double = 14

    static func pick(from connections: [ConnectionItem], now: Date = .now) -> ConnectionItem? {
        let snoozed = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return connections
            .filter { item in
                guard let last = item.lastActivityAt, now.timeIntervalSince(last) > quietDays * 86_400 else { return false }
                if let until = snoozed[item.userID], until > now.timeIntervalSince1970 { return false }
                return true
            }
            .sorted { ($0.isCore ? 0 : 1, $0.lastActivityAt ?? .distantPast) < ($1.isCore ? 0 : 1, $1.lastActivityAt ?? .distantPast) }
            .first
    }

    static func snooze(_ item: ConnectionItem, days: Double = 7) {
        var snoozed = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        snoozed[item.userID] = Date().addingTimeInterval(days * 86_400).timeIntervalSince1970
        UserDefaults.standard.set(snoozed, forKey: key)
    }
}

/// "Reconnect with Marcus": when you last talked and where you met, then Say hi or Not now.
struct ReconnectCard: View {
    let person: ConnectionItem
    let onSayHi: () -> Void
    let onProfile: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        HomePersonPrompt(
            title: "Reconnect with \(HomeFeedModel.firstName(person.displayName) ?? person.displayName)",
            detail: context.nonEmptyTrimmed,
            primaryTitle: "Say hi",
            onPrimary: onSayHi,
            secondaryTitle: "Not now",
            onSecondary: onNotNow,
            onOpen: onProfile
        ) {
            AvatarView(imageURL: person.avatarUrl, seed: person.userID, initials: person.initials,
                       size: ClickMetrics.Avatar.row, isCore: person.isCore)
        }
    }

    private var context: String {
        let last = person.lastActivityAt.map { "Last talked \($0.formatted(.dateTime.month(.abbreviated).day()))" }
        return [last, person.encounterLocation.nonEmptyTrimmed.map { "met at \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Home's "View all": every event you host, are going to or saved that hasn't ended, by day.
struct UpcomingEventsView: View {
    @Environment(AppEnvironment.self) private var env
    private var model: HomeFeedModel { env.homeFeed }

    var body: some View {
        let events = model.upcoming(excluding: nil)
        List {
            ForEach(Self.days(events), id: \.title) { day in
                Section(day.title) {
                    ForEach(day.events) { event in
                        Button { env.router.navigate(to: .event(beaconID: event.id)) } label: {
                            UpcomingEventRow(event: event)
                                .padding(.horizontal, -18)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if events.isEmpty {
                if model.hasUpcomingAnswer {
                    ContentUnavailableView {
                        Label("Nothing coming up", systemImage: "calendar")
                    } description: {
                        Text("Events you host, RSVP to or save appear here.")
                    } actions: {
                        Button("Find Events") { env.router.showOnMap(.layer(.events)) }
                    }
                } else if let message = model.myEvents.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load your events", systemImage: "exclamationmark.arrow.circlepath")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ClickLoadingView()
                }
            }
        }
        .navigationTitle("Upcoming")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        async let mine: Void = model.reloadMyEvents()
        async let saved: Void = env.selfData.loadSavedEvents(force: true)
        _ = await (mine, saved)
    }

    /// "Today", "Tomorrow", then "Thu, Oct 8"; a live event sits under today.
    nonisolated static func days(_ events: [HomeUpcomingEvent], now: Date = .now, calendar: Calendar = .current) -> [(title: String, events: [HomeUpcomingEvent])] {
        var days: [(title: String, events: [HomeUpcomingEvent])] = []
        for event in events {
            let day = max(event.schedule.start, now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            let title = if calendar.isDate(day, inSameDayAs: now) {
                "Today"
            } else if calendar.isDate(day, inSameDayAs: tomorrow) {
                "Tomorrow"
            } else {
                day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
            if days.last?.title == title {
                days[days.count - 1].events.append(event)
            } else {
                days.append((title, [event]))
            }
        }
        return days
    }
}
