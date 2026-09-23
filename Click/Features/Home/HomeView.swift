import SwiftUI

/// Authenticated Home root. Layout follows Click's Functional Clarity hierarchy while relying on
/// native scrolling, refresh, sheets, and navigation behavior.
public struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot: HomeFeedSnapshot?
    @State private var refreshError: String?
    @State private var isSearching = false

    public init(initialSnapshot: HomeFeedSnapshot? = nil) {
        self._snapshot = State(initialValue: initialSnapshot)
    }

    public var body: some View {
        Group {
            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if refreshError != nil {
                            cachedDataBanner
                        }

                        greeting(snapshot)
                        HomeSearchPill { isSearching = true }

                        if !snapshot.intents.isEmpty {
                            availabilitySection(snapshot.intents)
                        }

                        if let event = snapshot.featuredEvent {
                            section(title: "Happening Nearby") {
                                FeaturedEventCard(event: event) {
                                    env.router.selectedTab = .map
                                    env.router.mapPath.append(.event(beaconID: event.id))
                                }
                            }
                        }

                        if !snapshot.nearbyBeacons.isEmpty {
                            section(title: "Explore Nearby") {
                                VStack(spacing: 0) {
                                    ForEach(snapshot.nearbyBeacons) { beacon in
                                        ExploreBeaconTile(beacon: beacon) {
                                            env.router.selectedTab = .map
                                            env.router.mapPath.append(.beacon(beaconID: beacon.id))
                                        }

                                        if beacon.id != snapshot.nearbyBeacons.last?.id {
                                            Divider()
                                                .overlay(ClickColors.quietBorder.opacity(0.62))
                                                .padding(.leading, 58)
                                        }
                                    }
                                }
                                .clickSurface()
                            }
                        }

                        if !snapshot.recentConnections.isEmpty {
                            recentSection(snapshot.recentConnections)
                        }

                        statsSection(snapshot.stats)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .refreshable { await refresh() }
            } else {
                loadingState
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await bootstrap() }
        .sheet(isPresented: $isSearching) {
            HomeSearchSheetView()
        }
    }

    private func greeting(_ snapshot: HomeFeedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(HomeFeedSnapshot.timeBasedSalutation(for: snapshot.greetingName))
                .font(ClickTypography.headlineLarge)
                .tracking(-0.6)
                .foregroundStyle(ClickColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.greetingSubtitle)
                .font(ClickTypography.bodyMedium)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func availabilitySection(_ intents: [AvailabilityIntent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("I'm down for…")
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(intents) { intent in
                        AvailabilityIntentPill(intent: intent, onToggle: nil)
                    }
                }
            }
            .contentMargins(.horizontal, 1, for: .scrollContent)
        }
    }

    private func recentSection(_ connections: [RecentConnectionSummary]) -> some View {
        section(title: "Recent Encounters", accessory: "\(connections.count) shown") {
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
                        Divider()
                            .overlay(ClickColors.quietBorder.opacity(0.62))
                            .padding(.leading, 62)
                    }
                }
            }
            .clickSurface()
        }
    }

    private func statsSection(_ stats: HomeStats) -> some View {
        section(title: "Your Stats") {
            HStack(spacing: 0) {
                HomeStatCard(title: "Clicks", value: stats.totalClicks, iconName: "person.2.fill")
                Divider().frame(height: 38)
                HomeStatCard(title: "Encounters", value: stats.totalEncounters, iconName: "mappin")
                Divider().frame(height: 38)
                HomeStatCard(title: "Circles", value: stats.totalCircles, iconName: "circle.grid.3x3.fill")
            }
            .padding(.vertical, 14)
            .clickSurface()
        }
    }

    private func section<Content: View>(
        title: String,
        accessory: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(ClickTypography.titleSmall)
                    .foregroundStyle(ClickColors.textPrimary)

                Spacer()

                if let accessory {
                    Text(accessory)
                        .font(ClickTypography.captionSmall)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }

            content()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(ClickColors.primary)
            Text("Loading Home…")
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cachedDataBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))

            Text("Showing saved data")
                .font(ClickTypography.captionSmall)

            Spacer()

            Button("Retry") {
                Task { await refresh() }
            }
            .font(ClickTypography.captionSmall)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ClickColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
        }
    }

    @MainActor
    private func bootstrap() async {
        guard snapshot == nil,
              let userID = env.session.currentSession?.userId else { return }

        if let cached = await env.phase3.cachedHome(for: userID) {
            snapshot = cached
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard let userID = env.session.currentSession?.userId else { return }

        do {
            snapshot = try await env.phase3.refreshHome(for: userID)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
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
                        Label("Search your Clicks", systemImage: "magnifyingglass")
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
                                Circle()
                                    .fill(ClickColors.primaryFixed.opacity(0.48))
                                    .frame(width: 40, height: 40)
                                    .overlay {
                                        Text(connection.initials)
                                            .font(ClickTypography.labelMedium)
                                            .foregroundStyle(ClickColors.primary)
                                    }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.displayName)
                                        .font(ClickTypography.bodyMedium)
                                        .foregroundStyle(ClickColors.textPrimary)

                                    if !connection.handle.isEmpty {
                                        Text(connection.handle)
                                            .font(ClickTypography.bodySmall)
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
            .searchable(text: $query, prompt: "Names, places, interests")
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
        .tint(ClickColors.primary)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension View {
    func clickSurface() -> some View {
        self
            .background(ClickColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ClickSpacing.radiusCard, style: .continuous)
                    .stroke(ClickColors.quietBorder.opacity(0.72), lineWidth: ClickSpacing.borderQuietWidth)
            }
    }
}
