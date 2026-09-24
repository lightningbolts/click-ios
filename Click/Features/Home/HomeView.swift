import SwiftUI

/// Home: a linear social feed (spec §20.2, prototype hierarchy).
///
/// 1. greeting + search · 2. "I'm down for…" · 3. one social opportunity · 4. recent people ·
/// 5. recap · 6. saved & upcoming · 7. nearby discovery · 8. insights.
///
/// The scaffold never waits on a request: each module renders its own cached / loading /
/// empty / error state from `HomeFeedModel`, and recent people/insights come from the
/// shell-owned inbox model.
public struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @State private var model = HomeFeedModel()
    @State private var isSearching = false
    @State private var isEditingAvailability = false
    @State private var reconnectTick = 0
    @State private var showsCompactTitle = false

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
                        onResolveNudge: { nudge, action in
                            Task { await model.resolveNudge(nudge, action: action) }
                        }
                    )
                    .transition(.opacity)
                }
                recentPeopleSection(promoted: opportunity)
                recapSection
                savedSection(promotedID: promotedEventID(opportunity))
                nearbySection
                insightsSection
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .animation(ClickMotion.subtleFade, value: opportunity?.id)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .refreshable {
            async let feed: Void = model.refresh()
            async let inbox: Void = conversations.refresh()
            _ = await (feed, inbox)
        }
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
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSearching = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
        }
        .task {
            model.attach(env)
            await model.loadIfNeeded()
        }
        .sheet(isPresented: $isSearching) {
            GlobalSearchView()
        }
        .sheet(isPresented: $isEditingAvailability) {
            AvailabilitySheet {
                Task { await model.reloadIntents() }
            }
        }
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

            Button {
                ClickHaptics.selection()
                isSearching = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search people, places, events")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(ClickTypography.body)
                .foregroundStyle(ClickColors.textTertiary)
                .padding(.horizontal, 14)
                .frame(minHeight: ClickMetrics.searchMinHeight)
                .background(ClickColors.fillSubtle, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityLabel("Search people, places, events")

            if model.isShowingOfflineData {
                OfflineNotice("Offline — showing saved data") {
                    Task { await model.refresh() }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 2. Availability

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
                } else if model.intents.isPending {
                    HomeRow(inset: 60) {
                        ProgressView().frame(width: 28)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recent connections")
                        .font(ClickTypography.sectionTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                    Spacer()
                    Button("See all") { env.router.selectTab(.connections) }
                        .font(ClickTypography.body)
                        .foregroundStyle(ClickColors.textTertiary)
                }
                .padding(.horizontal, 18)

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
                                            presence: AvatarView.Presence(isOnline: item.isOnline, known: item.presenceKnown)
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
                        onMessage: { message(secondaryNudge) },
                        onDismiss: { Task { await model.resolveNudge(secondaryNudge, action: .dismiss) } }
                    )
                    .padding(.horizontal, 18)
                }
            }
            .padding(.vertical, 18)
            .groupedSurface()
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

    // MARK: - 6. Saved & upcoming

    @ViewBuilder
    private func savedSection(promotedID: String?) -> some View {
        let upcoming = model.upcomingSaved(excluding: promotedID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HomeSectionTitle("Saved & upcoming")
                Spacer()
                Button("All saved") { env.router.navigate(to: .savedEvents) }
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.accentForeground)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if model.savedEvents.value != nil {
                    if upcoming.isEmpty {
                        HomeEmptyRow(
                            text: "Bookmark events to keep them here.",
                            actionTitle: "Explore the map"
                        ) {
                            env.router.showOnMap(.layer(.events))
                        }
                    } else {
                        ForEach(upcoming.prefix(3)) { event in
                            Button { openEvent(event.beaconID) } label: {
                                SavedEventRow(event: event)
                            }
                            .buttonStyle(.plain)
                            if event.id != upcoming.prefix(3).last?.id {
                                HomeDivider(inset: 82)
                            }
                        }
                    }
                } else if model.savedEvents.isPending {
                    HomeLoadingRow()
                } else {
                    HomeRetryRow(message: "Couldn't load saved events.") {
                        Task { await model.refresh() }
                    }
                }
            }
            .groupedSurface()
        }
    }

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
                                    DiscoveryChip(title: entry.kind.pluralLabel, count: entry.count) {
                                        env.router.showOnMap(.layer(MapLayer(kind: entry.kind)))
                                    }
                                }
                                if !discovery.hubs.isEmpty {
                                    DiscoveryChip(title: "Hubs", count: discovery.hubs.count) {
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

    private func message(_ nudge: InboxNudge) {
        message(.nudge(nudge))
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
