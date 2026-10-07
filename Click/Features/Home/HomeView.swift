import SwiftUI

/// Home: a linear social feed (spec §20.2, prototype hierarchy).
///
/// 1. greeting + search · 2. "I'm down for…" · 3. one social opportunity · Click Drops · upcoming and
/// recommended events · 4. recent people · 5. recap · 7. nearby discovery · 8. insights.
///
/// The scaffold never waits on a request: each module renders its own cached / loading /
/// empty / error state from `HomeFeedModel`, and recent people/insights come from the
/// shell-owned inbox model.
public struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    private var model: HomeFeedModel { env.homeFeed }
    @State private var isEditingAvailability = false
    @State private var reconnectTick = 0
    @State private var showsCompactTitle = false
    @State private var reconnectNudge: ReconnectNearbyNudge?

    public init() {}

    public var body: some View {
        let opportunity = model.opportunity(connections: conversations.active)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                header
                availabilitySection
                if let opportunity {
                    HomeOpportunitySection(
                        opportunity: opportunity,
                        person: person(for: opportunity),
                        onOpenEvent: { openEvent($0) },
                        onShowOnMap: { env.router.showOnMap(.beacon($0)) },
                        onMessage: { message($0) },
                        onNudgeAction: { act(on: $0) },
                        onDeclineHangout: { nudge in Task { await model.declineHangout(nudge) } },
                        onResolveNudge: { nudge, action in
                            Task { await model.resolveNudge(nudge, action: action) }
                        }
                    )
                    .frame(minHeight: HomeFeedModel.opportunityPlaceholderHeight, alignment: .top)
                    // No reserved empty box while it loads (most visits have no card); it fades in.
                    .transition(.opacity)
                }
                if let nudge = reconnectNudge { ReconnectNearbyCard(nudge: nudge) { reconnectNudge = nil } }
                if env.features.isEnabled(.sharedDrops) { SharedDropsStrip() }
                upcomingSection(promotedID: promotedEventID(opportunity))
                HomeSetupCard()
                recentPeopleSection(promoted: opportunity)
                if env.features.isEnabled(.eventHistory), let recapCard = model.recapCard { HomeEventRecapCard(card: recapCard) }
                recapSection
                nearbySection
                insightsSection
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.bottom, 32)
            // Only the card appearing or leaving animates; swapping one opportunity for another
            // updates in place instead of replaying every section's entrance.
            .animation(ClickMotion.subtleFade, value: opportunity == nil)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .clickToast(Bindable(model).actionNotice)
        .refreshable { await refreshAll() }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 48
        } action: { _, scrolledPastGreeting in
            showsCompactTitle = scrolledPastGreeting
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Home")
                    .font(.headline)
                    .opacity(showsCompactTitle ? 1 : 0)
                    .animation(ClickMotion.subtleFade, value: showsCompactTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarLeading) {
                RootMenu {
                    Section {
                        if env.features.isEnabled(.sharedDrops) {
                            Button("Share a drop", systemImage: "camera") { env.sharedDropsStore.cameraRequested = true }
                        }
                        Button("I'm down for…", systemImage: "hand.wave") { isEditingAvailability = true }
                    }
                    Section {
                        Button("Search", systemImage: "magnifyingglass") { env.router.presentSearch() }
                        Button("Activity", systemImage: "bell") { env.router.navigate(to: .activity) }
                        EventHistoryMenuItem()
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refreshAll() }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ActivityBellButton()
            }
        }
        .task {
            model.attach(env)
            await model.loadIfNeeded()
        }
        // Flag-gated cards load here (a view that starts empty would never run its own task).
        .task(id: [env.features.isEnabled(.reconnectNearby), env.features.isEnabled(.eventHistory)]) {
            if env.features.isEnabled(.eventHistory) { await model.loadRecapCard() }
            if env.features.isEnabled(.reconnectNearby) {
                let nudge = await ReconnectNearbyCard.load(env)
                withAnimation(ClickMotion.subtleFade) { reconnectNudge = nudge }
            }
        }
        // Re-asks when the viewer's plans, their Clicks, or a Click's availability change.
        .task(id: [model.intents.value?.map(\.id).joined() ?? "", String(conversations.active.count), String(model.overlapsRevision)]) {
            await model.loadOverlaps(peerIDs: conversations.active.map(\.userID).filter { !$0.isEmpty })
        }
        .sheet(isPresented: $isEditingAvailability) {
            AvailabilitySheet {
                Task { await model.reloadIntents() }
            }
        }
    }

    /// Every module on Home, at once (pull to refresh and the menu's Refresh).
    private func refreshAll() async {
        async let feed: Void = model.refresh()
        async let inbox: Void = conversations.refresh()
        async let drops: Void = refreshDrops()
        _ = await (feed, inbox, drops)
    }

    private func refreshDrops() async {
        guard env.features.isEnabled(.sharedDrops) else { return }
        await env.sharedDropsStore.refresh(env: env)
    }

    // MARK: - 1. Greeting + search

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HomeGreeting.salutation(for: model.firstName))
                .font(ClickTypography.largeTitle)
                .foregroundStyle(ClickColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Ready to connect today?")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textTertiary)

            SearchLaunchField()
                .padding(.top, 12)

            OfflineNotice(showing: "saved data", hasCachedValue: model.hasCachedData, refreshFailed: model.hasRefreshFailure) {
                Task { await model.refresh() }
            }
            .padding(.top, 8)
        }
        // Flush with the gutter, like the native large title and search field on Clicks.
    }

    // MARK: - 2. Availability

    /// Clicks who are free for the same thing or at the same time (`get_availability_overlaps`).
    @ViewBuilder
    private var overlapRow: some View {
        let people = conversations.active.filter { model.overlappingPeerIDs.contains($0.userID) }
        if let title = HomeFeedModel.overlapTitle(names: people.map { HomeFeedModel.firstName($0.displayName) ?? $0.displayName }) {
            HomeRow(inset: 60) {
                AvatarView(imageURL: people[0].avatarUrl, seed: people[0].userID, initials: people[0].initials, size: 28, isCore: people[0].isCore)
            } content: {
                Text(title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(1)
                Text("Matching plans · say hi")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            }
            .accessibilityElement(children: .combine)
            HomeDivider(inset: 60)
        }
    }

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HomeCaption("I'm down for…")
            VStack(spacing: 0) {
                if let intents = model.intents.value {
                    ForEach(intents) { intent in
                        Button { isEditingAvailability = true } label: {
                            HomeRow(inset: 60) {
                                Circle()
                                    .fill(ClickColors.online)
                                    .frame(width: 12, height: 12)
                                    .frame(width: 28)
                            } content: {
                                Text(intent.tag)
                                    .font(ClickTypography.body)
                                    .foregroundStyle(ClickColors.textPrimary)
                                    .lineLimit(1)
                                Text("Visible to your Clicks · \(AvailabilityFormatting.until(intent).lowercased())")
                                    .font(ClickTypography.supporting)
                                    .foregroundStyle(ClickColors.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        HomeDivider(inset: 60)
                    }
                    overlapRow
                } else if model.intents.isPending {
                    HomeRow(inset: 60) {
                        ShimmerPlaceholder(cornerRadius: 14, width: 28, height: 28, animated: false)
                    } content: {
                        Text("Loading your plans…")
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                    HomeDivider(inset: 60)
                } else if model.intents.errorMessage != nil {
                    HomeRetryRow(message: "Couldn't load your plans.") {
                        Task { await model.reloadIntents() }
                    }
                    HomeDivider(inset: 60)
                }

                Button {
                    ClickHaptics.selection()
                    isEditingAvailability = true
                } label: {
                    HomeRow(inset: 60) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .frame(width: 28)
                    } content: {
                        Text((model.intents.value ?? []).isEmpty ? "Share what you're down for" : "Add or change plans")
                            .font(ClickTypography.body)
                    }
                    .foregroundStyle(ClickColors.accentForeground)
                }
                .buttonStyle(.plain)
            }
            .groupedSurface()
        }
    }

    // MARK: - 4. Recent people

    @ViewBuilder
    private func recentPeopleSection(promoted: HomeOpportunity?) -> some View {
        let recent = Array(
            conversations.active
                .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
                .prefix(10)
        )
        // A second nudge (one not already promoted above) sits under the strip, never twice.
        let secondaryNudge = model.visibleNudges.first { nudge in
            if case .nudge(let promotedNudge) = promoted { return nudge.id != promotedNudge.id }
            return true
        }

        if !recent.isEmpty || conversations.snapshot == nil {
            VStack(alignment: .leading, spacing: 10) {
            Button { env.router.selectTab(.connections) } label: {
                HStack(alignment: .firstTextBaseline) {
                    HomeSectionTitle("Recent connections")
                    Spacer()
                    Text("See all")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ClickColors.textTertiary)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 12) {
                if recent.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(spacing: 6) {
                                Circle().fill(ClickColors.fillSubtle).frame(width: 64, height: 64)
                                Capsule().fill(ClickColors.fillSubtle).frame(width: 44, height: 10)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .accessibilityLabel("Loading recent connections")
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(recent) { item in
                                Button { openProfile(item) } label: {
                                    VStack(spacing: 4) {
                                        AvatarView(
                                            imageURL: item.avatarUrl,
                                            seed: item.userID,
                                            initials: item.initials,
                                            size: 64,
                                            presence: AvatarView.Presence(isOnline: item.isOnline, known: item.presenceKnown),
                                            isCore: item.isCore
                                        )
                                        Text(HomeFeedModel.firstName(item.displayName) ?? item.displayName)
                                            .font(ClickTypography.supporting)
                                            .foregroundStyle(ClickColors.textPrimary)
                                            .lineLimit(1)
                                        if !item.lastActiveRelative.isEmpty {
                                            Text(item.lastActiveRelative)
                                                .font(ClickTypography.caption)
                                                .foregroundStyle(ClickColors.textTertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(width: 72)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.displayName), \(item.lastActiveRelative)")
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden)
                }

                if secondaryNudge == nil, let suggestion = ReconnectSuggestion.pick(from: conversations.active) {
                    HomeDivider(inset: 18).padding(.trailing, 18)
                    ReconnectCard(
                        person: suggestion,
                        onSayHi: { openChat(suggestion) },
                        onProfile: { openProfile(suggestion) },
                        onNotNow: { ReconnectSuggestion.snooze(suggestion) ; reconnectTick += 1 }
                    )
                    .id(reconnectTick)
                    .padding(.horizontal, 18)
                } else if let secondaryNudge {
                    HomeDivider(inset: 18).padding(.trailing, 18)
                    HomeNudgeRow(
                        nudge: secondaryNudge,
                        person: conversationItem(connectionID: secondaryNudge.connectionID),
                        onPrimary: { act(on: secondaryNudge) },
                        onDecline: { Task { await model.declineHangout(secondaryNudge) } },
                        onDismiss: { Task { await model.resolveNudge(secondaryNudge, action: .dismiss) } }
                    )
                    .padding(.horizontal, 18)
                }
            }
            .padding(.vertical, 18)
            .groupedSurface()
            }
        }
    }

    // MARK: - 5. Recap

    private var recapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HomeSectionTitle("Your recap")
                Spacer()
                Picker("Recap window", selection: Binding(
                    get: { model.recapWindow },
                    set: { window in Task { await model.selectRecapWindow(window) } }
                )) {
                    Text("Day").tag(ActivityRecap.Window.day)
                    Text("Week").tag(ActivityRecap.Window.week)
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
            }
            .padding(.horizontal, 4)

            let state = model.recap
            VStack(spacing: 0) {
                if let recap = state.value {
                    if recap.isEmpty {
                        HomeEmptyRow(
                            text: "No activity this \(recap.window.rawValue) yet.",
                            actionTitle: "Make your first Click"
                        ) {
                            env.router.selectTab(.addClick)
                        }
                    } else {
                        ForEach(recapRows(recap), id: \.label) { row in
                            HStack {
                                Text(row.label)
                                    .font(ClickTypography.body)
                                    .foregroundStyle(ClickColors.textSecondary)
                                Spacer()
                                Text(row.value, format: .number)
                                    .font(ClickTypography.bodyEmphasized)
                                    .foregroundStyle(ClickColors.textPrimary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 48)
                            .accessibilityElement(children: .combine)
                            if row.label != recapRows(recap).last?.label {
                                HomeDivider(inset: 18)
                            }
                        }
                    }
                } else if state.isPending {
                    HomeLoadingRow()
                } else {
                    // Never a zero recap when the request failed (spec §20.3).
                    HomeRetryRow(message: "Couldn't load your recap.") {
                        Task { await model.selectRecapWindow(model.recapWindow) }
                    }
                }
            }
            .groupedSurface()

            if state.isStale {
                Text("Showing your last saved recap.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func recapRows(_ recap: ActivityRecap) -> [(label: String, value: Int)] {
        [
            ("New Clicks", recap.connectionsFormed),
            ("Messages sent", recap.messagesSent),
            ("Messages received", recap.messagesReceived),
            ("Events RSVP'd", recap.eventsRSVPed),
            ("Check-ins", recap.eventsCheckedIn),
            ("Events saved", recap.eventsSaved),
            ("Beacons dropped", recap.beaconsCreated)
        ].filter { $0.1 > 0 }
    }

    // MARK: - 6. Upcoming & recommended

    /// Events you host, are going to or saved (soonest first, "View all" for the rest), then
    /// events near you picked for you.
    @ViewBuilder
    private func upcomingSection(promotedID: String?) -> some View {
        let upcoming = model.upcoming(excluding: promotedID)
        let recommendations = model.recommendations(excluding: promotedID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HomeSectionTitle("Upcoming")
                Spacer()
                if !upcoming.isEmpty {
                    Button { env.router.navigate(to: .upcomingEvents) } label: {
                        HStack(spacing: 4) {
                            Text("View all")
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(ClickColors.textTertiary)
                        }
                    }
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if !upcoming.isEmpty {
                    let shown = upcoming.prefix(Self.upcomingShown)
                    ForEach(shown) { event in
                        Button { openEvent(event.id) } label: {
                            UpcomingEventRow(event: event)
                        }
                        .buttonStyle(.plain)
                        if event.id != shown.last?.id {
                            HomeDivider(inset: 82)
                        }
                    }
                } else if model.hasUpcomingAnswer {
                    HomeEmptyRow(
                        text: recommendations.isEmpty ? "Events you're going to show up here." : "Nothing on your calendar yet.",
                        actionTitle: "Find events"
                    ) {
                        env.router.showOnMap(.layer(.events))
                    }
                } else if model.myEvents.isPending || model.savedEvents.isPending {
                    HomeLoadingRow()
                } else {
                    HomeRetryRow(message: "Couldn't load your events.") {
                        Task { await model.refresh() }
                    }
                }
            }
            .groupedSurface()

            if !recommendations.isEmpty {
                Text("Recommended for you")
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                ScrollView(.horizontal) {
                    // Eager (at most `HomeRecommendations.limit` cards) so every card can take the
                    // tallest one's height and their buttons line up.
                    HStack(spacing: 12) {
                        ForEach(recommendations) { recommendation in
                            HomeEventCard(
                                beaconID: recommendation.id,
                                imageURL: recommendation.beacon.imageURL,
                                pill: StatusPill(recommendation.reason.text, style: recommendation.reason == .live ? .live : .neutral),
                                title: recommendation.beacon.title,
                                detail: recommendation.detail(),
                                onOpen: { openEvent(recommendation.id) },
                                onShowOnMap: { env.router.showOnMap(.beacon(recommendation.id)) }
                            )
                            .frame(maxHeight: .infinity)
                            .groupedSurface()
                            // Happening now's card at full width; with more than one, the next
                            // one peeks in so the row reads as scrollable.
                            .containerRelativeFrame(.horizontal) { width, _ in
                                min(recommendations.count == 1 ? width : width - 32, 460)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                // Cards scroll out to the screen's edges, past the page gutter.
                .scrollClipDisabled()
            }
        }
    }

    /// Upcoming rows on Home; "View all" shows the rest.
    private static let upcomingShown = 3

    // MARK: - 7. Nearby discovery

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HomeSectionTitle("Explore nearby")
                Spacer()
                Button("Open Map") { env.router.showOnMap() }
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.accentForeground)
            }
            .padding(.horizontal, 4)

            switch model.discovery.phase {
            case .unavailable(let reason):
                VStack(spacing: 0) {
                    HomeEmptyRow(text: reason, actionTitle: "Open Map") {
                        env.router.showOnMap()
                    }
                }
                .groupedSurface()
            default:
                if let discovery = model.discovery.value {
                    let counts = discovery.kindCounts()
                    if counts.isEmpty && discovery.hubs.isEmpty {
                        VStack(spacing: 0) {
                            HomeEmptyRow(text: "Nothing live near you right now.", actionTitle: "Drop a beacon") {
                                env.router.showOnMap()
                            }
                        }
                        .groupedSurface()
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(counts, id: \.kind) { entry in
                                    DiscoveryChip(title: entry.kind.pluralLabel, count: entry.count,
                                                  faces: Self.faces(of: entry.kind, in: discovery)) {
                                        env.router.showOnMap(.layer(MapLayer(kind: entry.kind)))
                                    }
                                }
                                if !discovery.hubs.isEmpty {
                                    DiscoveryChip(title: "Hubs", count: discovery.hubs.count,
                                                  faces: discovery.hubs.prefix(3).map { MapItem(kind: .hub($0)) }) {
                                        env.router.showOnMap(.layer(.hubs))
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .scrollIndicators(.hidden)
                        Text("Counts reflect what's live within about 5 km right now.")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textTertiary)
                            .padding(.horizontal, 4)
                    }
                } else if model.discovery.isPending {
                    VStack(spacing: 0) { HomeLoadingRow() }.groupedSurface()
                } else {
                    VStack(spacing: 0) {
                        HomeRetryRow(message: "Couldn't load what's nearby.") {
                            Task { await model.refresh() }
                        }
                    }
                    .groupedSurface()
                }
            }
        }
    }

    /// A few live beacons of a kind for its chip, those with a picture first.
    private static func faces(of kind: BeaconKind, in discovery: NearbyDiscovery, now: Date = .now) -> [MapItem] {
        let live = discovery.beacons.filter { $0.kind == kind && $0.isActive(at: now) }
        let pictured = live.filter { $0.imageURL?.nonEmptyTrimmed != nil }
        return (pictured + live.filter { $0.imageURL?.nonEmptyTrimmed == nil })
            .prefix(3)
            .map { MapItem(kind: .beacon($0)) }
    }

    // MARK: - 8. Insights

    @ViewBuilder
    private var insightsSection: some View {
        // Derived only from a loaded inbox; an unloaded inbox never becomes zero stats.
        if let snapshot = conversations.snapshot {
            let all = snapshot.connections + snapshot.archived
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionTitle("Insights")
                    .padding(.horizontal, 4)
                HStack(spacing: 10) {
                    InsightTile(value: all.count, label: all.count == 1 ? "Click" : "Clicks")
                    InsightTile(value: all.reduce(0) { $0 + $1.encounterCount }, label: "Encounters")
                    InsightTile(value: snapshot.connections.filter(\.isCore).count, label: "Core")
                }
            }
        }
    }

    // MARK: - Routing

    private func promotedEventID(_ opportunity: HomeOpportunity?) -> String? {
        if case .event(let event) = opportunity { return event.id }
        return nil
    }

    private func person(for opportunity: HomeOpportunity) -> ConnectionItem? {
        switch opportunity {
        case .event: nil
        case .nudge(let nudge): conversationItem(connectionID: nudge.connectionID)
        case .sayHi(let item, _): item
        }
    }

    private func conversationItem(connectionID: String?) -> ConnectionItem? {
        guard let connectionID else { return nil }
        return (conversations.active + conversations.archived).first { $0.connectionID == connectionID }
    }

    private func openEvent(_ beaconID: String) {
        ClickHaptics.selection()
        env.router.navigate(to: .event(beaconID: beaconID))
    }

    private func openProfile(_ item: ConnectionItem) {
        guard !item.userID.isEmpty else { return }
        ClickHaptics.selection()
        env.router.navigate(to: .userProfile(userID: item.userID, connectionID: item.connectionID.isEmpty ? nil : item.connectionID))
    }

    private func message(_ target: HomeMessageTarget) {
        switch target {
        case .connection(let item):
            openChat(item)
        case .nudge(let nudge):
            Task { await model.resolveNudge(nudge, action: .acted) }
            if let item = conversationItem(connectionID: nudge.connectionID) {
                openChat(item)
            } else {
                env.router.selectTab(.connections)
            }
        }
    }

    /// A nudge's primary action, by kind.
    private func act(on nudge: InboxNudge) {
        switch nudge.kind {
        case .hangoutConfirm:
            Task { await model.confirmHangout(nudge) }
        case .wave:
            Task { await model.waveBack(nudge) }
        case .memoryPrompt:
            Task { await model.resolveNudge(nudge, action: .acted) }
            if let userID = nudge.peerUserID ?? conversationItem(connectionID: nudge.connectionID)?.userID {
                ClickHaptics.selection()
                env.router.navigate(to: .userProfile(userID: userID, connectionID: nudge.connectionID))
            }
        case .groupRevival:
            Task { await model.resolveNudge(nudge, action: .acted) }
            guard let chatID = nudge.chatID else { return }
            ClickHaptics.selection()
            let route = conversations.groups.first { $0.chatID == chatID }?.chatRoute
                ?? GroupChatRoute(chatID: chatID, groupID: nudge.groupID ?? chatID, name: nudge.groupName ?? "Group")
            env.router.navigate(to: .groupChat(route))
        case .reconnectLull, .sharedUpcomingEvent, .anniversary:
            message(.nudge(nudge))
        }
    }

    private func openChat(_ item: ConnectionItem) {
        guard !item.userID.isEmpty else { return }
        ClickHaptics.selection()
        conversations.markOpened(item)
        env.router.navigate(to: .chat(DirectChatRoute(
            chatID: item.chatID,
            connectionID: item.connectionID,
            peerUserID: item.userID,
            peerDisplayName: item.displayName,
            peerHandle: item.handle,
            peerAvatarURL: item.avatarUrl,
            isOnline: item.isOnline,
            lastActiveText: item.lastActiveRelative
        )))
    }
}

/// What a Home "Message / Say hi" action targets.
enum HomeMessageTarget {
    case connection(ConnectionItem)
    case nudge(InboxNudge)
}
