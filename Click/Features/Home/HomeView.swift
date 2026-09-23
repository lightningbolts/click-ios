import SwiftUI

/// Phase 3 native Home tab backed by authenticated server state with last-known-good cache fallback.
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
                    VStack(alignment: .leading, spacing: ClickSpacing.lg) {
                        if refreshError != nil {
                            cachedDataBanner
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xxs) {
                            Text(HomeFeedSnapshot.timeBasedSalutation(for: snapshot.greetingName))
                                .font(ClickTypography.headlineLarge)
                                .tracking(-0.5)
                                .foregroundStyle(ClickColors.textPrimary)

                            Text(snapshot.greetingSubtitle)
                                .font(ClickTypography.bodyMedium)
                                .foregroundStyle(ClickColors.textSecondary)
                        }
                        .padding(.top, ClickSpacing.sm)

                        HomeSearchPill { isSearching = true }

                        if !snapshot.intents.isEmpty {
                            VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                                Text("I'm down for…")
                                    .font(ClickTypography.titleSmall)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ClickColors.textPrimary)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: ClickSpacing.xs) {
                                        ForEach(snapshot.intents) { intent in
                                            AvailabilityIntentPill(intent: intent, onToggle: nil)
                                        }
                                    }
                                }
                            }
                        }

                        if let event = snapshot.featuredEvent {
                            VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                                Text("Happening Nearby")
                                    .font(ClickTypography.titleSmall)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ClickColors.textPrimary)

                                FeaturedEventCard(event: event) {
                                    env.router.selectedTab = .map
                                    env.router.mapPath.append(.event(beaconID: event.id))
                                }
                            }
                        }

                        if !snapshot.nearbyBeacons.isEmpty {
                            VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                                Text("Explore Nearby")
                                    .font(ClickTypography.titleSmall)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ClickColors.textPrimary)

                                VStack(spacing: ClickSpacing.xs) {
                                    ForEach(snapshot.nearbyBeacons) { beacon in
                                        ExploreBeaconTile(beacon: beacon) {
                                            env.router.selectedTab = .map
                                            env.router.mapPath.append(.beacon(beaconID: beacon.id))
                                        }
                                    }
                                }
                            }
                        }

                        if !snapshot.recentConnections.isEmpty {
                            VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                                HStack {
                                    Text("Recent Encounters")
                                        .font(ClickTypography.titleSmall)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(ClickColors.textPrimary)
                                    Spacer()
                                    Text("\(snapshot.recentConnections.count) shown")
                                        .font(ClickTypography.labelSmall)
                                        .foregroundStyle(ClickColors.textSecondary)
                                }

                                VStack(spacing: 0) {
                                    ForEach(snapshot.recentConnections) { connection in
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

                                        if connection.id != snapshot.recentConnections.last?.id {
                                            Divider()
                                                .background(ClickColors.quietBorder)
                                                .padding(.leading, 64)
                                        }
                                    }
                                }
                                .padding(.horizontal, ClickSpacing.md)
                                .padding(.vertical, ClickSpacing.xs)
                                .background(ClickColors.surfaceContainerLow)
                                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
                            }
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                            Text("Your Stats")
                                .font(ClickTypography.titleSmall)
                                .fontWeight(.semibold)
                                .foregroundStyle(ClickColors.textPrimary)

                            HStack(spacing: ClickSpacing.sm) {
                                HomeStatCard(title: "Total Clicks", value: snapshot.stats.totalClicks, iconName: "person.2.circle.fill")
                                HomeStatCard(title: "Encounters", value: snapshot.stats.totalEncounters, iconName: "mappin.circle.fill")
                                HomeStatCard(title: "Circles", value: snapshot.stats.totalCircles, iconName: "circle.grid.3x3.fill")
                            }
                        }
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.bottom, ClickSpacing.xxl)
                }
                .refreshable { await refresh() }
            } else {
                VStack(spacing: ClickSpacing.md) {
                    ProgressView()
                    Text("Loading Home…")
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .task { await bootstrap() }
        .sheet(isPresented: $isSearching) {
            HomeSearchSheetView()
        }
    }

    private var cachedDataBanner: some View {
        HStack(spacing: ClickSpacing.xs) {
            Image(systemName: "wifi.exclamationmark")
            Text("Showing your last saved data")
                .font(ClickTypography.labelMedium)
            Spacer()
            Button("Retry") {
                Task { await refresh() }
            }
            .font(ClickTypography.labelMedium)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(ClickSpacing.sm)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
    }

    @MainActor
    private func bootstrap() async {
        guard snapshot == nil, let userID = env.session.currentSession?.userId else { return }
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
            VStack(spacing: 0) {
                HStack(spacing: ClickSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ClickColors.outline)
                    TextField("Search your Clicks…", text: $query)
                        .font(ClickTypography.bodyMedium)
                }
                .padding(.horizontal, ClickSpacing.md)
                .padding(.vertical, 12)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                .padding(ClickSpacing.lg)

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Spacer()
                    Text("Search names, interests, and encounter places.")
                        .font(ClickTypography.bodySmall)
                        .foregroundStyle(ClickColors.textSecondary)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    Text("No matching Clicks")
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textSecondary)
                    Spacer()
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.displayName)
                                    .foregroundStyle(ClickColors.textPrimary)
                                if !connection.handle.isEmpty {
                                    Text(connection.handle)
                                        .font(ClickTypography.bodySmall)
                                        .foregroundStyle(ClickColors.textSecondary)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: query) {
                let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, let userID = env.session.currentSession?.userId else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                results = (try? await env.phase3.searchConnections(userID: userID, query: clean)) ?? []
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
