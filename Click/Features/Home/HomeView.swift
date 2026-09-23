import SwiftUI

/// Home keeps the cross-platform Click information hierarchy while using native SwiftUI
/// scrolling, sheets, toolbars, refresh, and navigation.
public struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot: HomeFeedSnapshot?
    @State private var refreshError: String?
    @State private var isSearching = false
    @State private var isEditingAvailability = false
    @State private var recapWindow: RecapWindow = .week
    @State private var displayedRecap: HomeActivityRecap?
    @State private var showsCompactTitle = false

    public init(initialSnapshot: HomeFeedSnapshot? = nil) {
        self._snapshot = State(initialValue: initialSnapshot)
        self._displayedRecap = State(initialValue: initialSnapshot?.recap)
    }

    public var body: some View {
        Group {
            if let snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if refreshError != nil {
                            offlineNotice
                        }

                        greeting(snapshot)

                        HomeSearchPill { isSearching = true }

                        availabilitySection(snapshot.intents)

                        recapSection(displayedRecap ?? snapshot.recap ?? .init())

                        if let event = snapshot.featuredEvent {
                            sectionHeader("Saved events")
                            FeaturedEventCard(event: event) {
                                env.router.selectedTab = .map
                                env.router.mapPath.append(.event(beaconID: event.id))
                            }
                        }

                        if !snapshot.nearbyBeacons.isEmpty {
                            nearbySection(snapshot.nearbyBeacons)
                        }

                        if !snapshot.recentConnections.isEmpty {
                            recentSection(snapshot.recentConnections)
                        }

                        statsSection(snapshot.stats)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 34)
                }
                .refreshable { await refresh() }
                // The greeting is Home's expanded title; the compact native title appears only
                // once it scrolls under the navigation bar.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 56
                } action: { _, isScrolledPastGreeting in
                    showsCompactTitle = isScrolledPastGreeting
                }
            } else {
                loadingState
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Home")
                    .font(.headline)
                    .opacity(showsCompactTitle || snapshot == nil ? 1 : 0)
                    .animation(ClickMotion.subtleFade, value: showsCompactTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    Button("Settings", systemImage: "gearshape.fill") {
                        env.router.selectedTab = .settings
                    }
                } label: {
                    Label("Home menu", systemImage: "ellipsis")
                }
            }
        }
        .task { await bootstrap() }
        .sheet(isPresented: $isSearching) {
            HomeSearchSheetView()
        }
        .sheet(isPresented: $isEditingAvailability) {
            AvailabilityIntentsSheet {
                Task { await refresh() }
            }
        }
        .onChange(of: recapWindow) { _, newValue in
            Task { await loadRecap(window: newValue) }
        }
    }

    private func greeting(_ snapshot: HomeFeedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(HomeFeedSnapshot.timeBasedSalutation(for: snapshot.greetingName))
                .font(ClickTypography.largeTitle)
                .tracking(-0.55)
                .foregroundStyle(ClickColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.greetingSubtitle)
                .font(ClickTypography.body)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func availabilitySection(_ intents: [AvailabilityIntent]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader("I'm down for…")

            if !intents.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(intents) { intent in
                            AvailabilityIntentPill(intent: intent)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Button {
                ClickHaptics.selection()
                isEditingAvailability = true
            } label: {
                Label(
                    intents.isEmpty ? "Set what you're down for" : "Manage what you're down for",
                    systemImage: "plus"
                )
            }
            .buttonStyle(.clickPrimary)
        }
    }

    private func recapSection(_ recap: HomeActivityRecap) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Your recap")

            HStack(spacing: 10) {
                recapWindowButton(.day)
                recapWindowButton(.week)
                Spacer()
            }

            VStack(spacing: 0) {
                recapRow("Connections formed", value: recap.connectionsFormed)
                recapRow("Messages sent", value: recap.messagesSent, emphasized: true)
                recapRow("Messages received", value: recap.messagesReceived)
                recapRow("Beacons created", value: recap.beaconsCreated)
                recapRow("Events RSVP'd", value: recap.eventsRSVPed)
                recapRow("Check-ins", value: recap.eventsCheckedIn)
                recapRow("Events saved", value: recap.eventsSaved)
            }
            .padding(.vertical, 8)
            .groupedSurface()
        }
    }

    private func recapWindowButton(_ value: RecapWindow) -> some View {
        Button {
            recapWindow = value
            ClickHaptics.selection()
        } label: {
            Text(value == .day ? "Day" : "Week")
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(recapWindow == value ? ClickColors.accentForeground : ClickColors.textPrimary)
                .padding(.horizontal, 18)
                .frame(minWidth: 92, minHeight: ClickMetrics.chipHeight)
                .background(recapWindow == value ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
                .frame(minHeight: ClickMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recapRow(_ title: String, value: Int, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(emphasized ? ClickTypography.bodyEmphasized : ClickTypography.body)
                .foregroundStyle(emphasized ? ClickColors.textPrimary : ClickColors.textSecondary)
            Spacer()
            Text("\(value)")
                .font(emphasized ? ClickTypography.bodyEmphasized : ClickTypography.body)
                .foregroundStyle(emphasized ? ClickColors.textPrimary : ClickColors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func nearbySection(_ beacons: [ExploreBeaconItem]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                sectionHeader("Explore Nearby")
                Spacer()
                Button("Map") { env.router.selectedTab = .map }
                    .font(ClickTypography.metadata)
            }

            VStack(spacing: 0) {
                ForEach(beacons) { beacon in
                    ExploreBeaconTile(beacon: beacon) {
                        env.router.selectedTab = .map
                        env.router.mapPath.append(.beacon(beaconID: beacon.id))
                    }
                    if beacon.id != beacons.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .groupedSurface()
        }
    }

    private func recentSection(_ connections: [RecentConnectionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                sectionHeader("Recent Connections")
                Spacer()
                Button("See all") {
                    env.router.selectedTab = .connections
                }
                .font(ClickTypography.metadata)
            }

            VStack(spacing: 0) {
                ForEach(connections) { connection in
                    RecentConnectionRowItem(connection: connection) {
                        guard !connection.userID.isEmpty else { return }
                        env.router.selectedTab = .connections
                        env.router.connectionsPath.append(
                            .userProfile(
                                userID: connection.userID,
                                connectionID: connection.connectionID.nonEmpty
                            )
                        )
                    }
                    if connection.id != connections.last?.id {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .groupedSurface()
        }
    }

    private func statsSection(_ stats: HomeStats) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader("Your Stats")
            HStack(spacing: 0) {
                HomeStatCard(title: "Clicks", value: stats.totalClicks, iconName: "person.2.fill")
                Divider().frame(height: 38)
                HomeStatCard(title: "Encounters", value: stats.totalEncounters, iconName: "mappin")
                Divider().frame(height: 38)
                HomeStatCard(title: "Circles", value: stats.totalCircles, iconName: "circle.grid.3x3.fill")
            }
            .padding(.vertical, 14)
            .groupedSurface()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(ClickColors.textPrimary)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(ClickColors.accentForeground)
            Text("Loading Home…")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineNotice: some View {
        OfflineNotice("Offline — showing saved data") {
            Task { await refresh() }
        }
    }

    @MainActor
    private func bootstrap() async {
        guard snapshot == nil,
              let userID = env.session.currentSession?.userId else { return }

        if let cached = await env.phase3.cachedHome(for: userID) {
            snapshot = cached
            displayedRecap = cached.recap
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard let userID = env.session.currentSession?.userId else { return }

        do {
            let fresh = try await env.phase3.refreshHome(for: userID)
            snapshot = fresh
            if recapWindow == .week {
                displayedRecap = fresh.recap
            }
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }

    @MainActor
    private func loadRecap(window: RecapWindow) async {
        do {
            let request = APIRequest(
                path: "/api/me/recap",
                method: .get,
                queryItems: [URLQueryItem(name: "window", value: window.rawValue)],
                requiresAuth: true
            )
            let (data, _) = try await env.api.executeRaw(request)
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let row = root["recap"] as? [String: Any]
            else { throw APIError.decoding }

            displayedRecap = HomeActivityRecap(
                connectionsFormed: Self.int(row["connections_formed"]),
                messagesSent: Self.int(row["messages_sent"]),
                messagesReceived: Self.int(row["messages_received"]),
                beaconsCreated: Self.int(row["beacons_created"]),
                eventsRSVPed: Self.int(row["events_rsvped"]),
                eventsCheckedIn: Self.int(row["events_checked_in"]),
                eventsSaved: Self.int(row["events_saved"])
            )
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }
}

private enum RecapWindow: String {
    case day
    case week
}

private struct AvailabilityIntentsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onChanged: () -> Void

    @State private var intents: [AvailabilityRow] = []
    @State private var tag = ""
    @State private var duration: DurationPreset = .fourHours
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if !intents.isEmpty {
                    Section("Active now") {
                        ForEach(intents) { intent in
                            HStack {
                                Text(intent.tag)
                                Spacer()
                                Text(intent.timeframe)
                                    .font(ClickTypography.metadata)
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await remove(intent) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("Add intent") {
                    TextField("Coffee, study session…", text: $tag)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: tag) { _, value in
                            if value.count > 25 { tag = String(value.prefix(25)) }
                        }

                    Picker("Duration", selection: $duration) {
                        ForEach(DurationPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }

                    Button {
                        Task { await addIntent() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label("Share availability", systemImage: "plus")
                        }
                    }
                    .disabled(tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(ClickColors.destructive)
                    }
                }
            }
            .navigationTitle("I'm down for…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .tint(ClickColors.accentForeground)
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let request = APIRequest(path: "/api/user/availability-intents", method: .get, requiresAuth: true)
            let (data, _) = try await env.api.executeRaw(request)
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rows = root["intents"] as? [[String: Any]]
            else { throw APIError.decoding }

            intents = rows.compactMap {
                guard let id = $0["id"] as? String else { return nil }
                let tag = ($0["intent_tag"] as? String) ?? "Available"
                let timeframe = ($0["timeframe"] as? String) ?? ""
                return AvailabilityRow(id: id, tag: tag, timeframe: timeframe)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addIntent() async {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "intent_tag": clean,
                "durationMs": duration.milliseconds
            ])
            let request = APIRequest(
                path: "/api/user/availability-intents",
                method: .post,
                body: body,
                requiresAuth: true
            )
            _ = try await env.api.executeRaw(request)
            tag = ""
            await load()
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func remove(_ row: AvailabilityRow) async {
        do {
            let request = APIRequest(
                path: "/api/user/availability-intents",
                method: .delete,
                queryItems: [URLQueryItem(name: "id", value: row.id)],
                requiresAuth: true
            )
            _ = try await env.api.executeRaw(request)
            intents.removeAll { $0.id == row.id }
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AvailabilityRow: Identifiable {
    let id: String
    let tag: String
    let timeframe: String
}

private enum DurationPreset: CaseIterable, Identifiable {
    case oneHour
    case fourHours
    case today

    var id: String { label }

    var label: String {
        switch self {
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .today: return "Today"
        }
    }

    var milliseconds: Int {
        switch self {
        case .oneHour: return 3_600_000
        case .fourHours: return 14_400_000
        case .today: return 43_200_000
        }
    }
}

private struct HomeSearchSheetView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ConnectionItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label("Search Click", systemImage: "magnifyingglass")
                    } description: {
                        Text("Find people by name, handle, place, or interest.")
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { connection in
                        Button {
                            dismiss()
                            env.router.selectedTab = .connections
                            env.router.connectionsPath.append(
                                .userProfile(
                                    userID: connection.userID,
                                    connectionID: connection.connectionID.nonEmpty
                                )
                            )
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(
                                    imageURL: connection.avatarUrl,
                                    initials: connection.initials,
                                    size: ClickMetrics.Avatar.row
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.displayName)
                                        .font(ClickTypography.body)
                                        .foregroundStyle(ClickColors.textPrimary)
                                    if !connection.handle.isEmpty {
                                        Text(connection.handle)
                                            .font(ClickTypography.supporting)
                                            .foregroundStyle(ClickColors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(ClickColors.background.ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "People, places, events")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: query) {
                let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty,
                      let userID = env.session.currentSession?.userId else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                results = (try? await env.phase3.searchConnections(userID: userID, query: clean)) ?? []
            }
        }
        .tint(ClickColors.accentForeground)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}


