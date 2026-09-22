import SwiftUI

/// Phase 3 native Home tab screen.
public struct HomeView: View {
    @State private var snapshot: HomeFeedSnapshot
    @State private var isSearching: Bool = false
    @State private var selectedConnectionId: String?

    public init(initialSnapshot: HomeFeedSnapshot = .preview) {
        self._snapshot = State(initialValue: initialSnapshot)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ClickSpacing.lg) {
                // Header Greeting
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

                // Search Pill
                HomeSearchPill {
                    isSearching = true
                }

                // "I'm down for…" Availability Intents
                VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                    Text("I'm down for…")
                        .font(ClickTypography.titleSmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(ClickColors.textPrimary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ClickSpacing.xs) {
                            ForEach(snapshot.intents) { intent in
                                AvailabilityIntentPill(intent: intent) {
                                    toggleIntent(intent.id)
                                }
                            }
                        }
                    }
                }

                // Featured Event
                if let event = snapshot.featuredEvent {
                    VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                        Text("Happening Nearby")
                            .font(ClickTypography.titleSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ClickColors.textPrimary)

                        FeaturedEventCard(event: event) {
                            // Event detail action
                        }
                    }
                }

                // Explore Nearby Beacons
                if !snapshot.nearbyBeacons.isEmpty {
                    VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                        HStack {
                            Text("Explore Nearby")
                                .font(ClickTypography.titleSmall)
                                .fontWeight(.semibold)
                                .foregroundStyle(ClickColors.textPrimary)
                            Spacer()
                            Text("Active Beacons")
                                .font(ClickTypography.labelSmall)
                                .foregroundStyle(ClickColors.primary)
                        }

                        VStack(spacing: ClickSpacing.xs) {
                            ForEach(snapshot.nearbyBeacons) { beacon in
                                ExploreBeaconTile(beacon: beacon) {
                                    // Beacon tap
                                }
                            }
                        }
                    }
                }

                // Recent Connections
                if !snapshot.recentConnections.isEmpty {
                    VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                        HStack {
                            Text("Recent Encounters")
                                .font(ClickTypography.titleSmall)
                                .fontWeight(.semibold)
                                .foregroundStyle(ClickColors.textPrimary)

                            Spacer()

                            Text("\(snapshot.recentConnections.count) connections")
                                .font(ClickTypography.labelSmall)
                                .foregroundStyle(ClickColors.textSecondary)
                        }

                        VStack(spacing: 0) {
                            ForEach(snapshot.recentConnections) { connection in
                                RecentConnectionRowItem(connection: connection) {
                                    selectedConnectionId = connection.id
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
                        .overlay(
                            RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                                .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                        )
                    }
                }

                // Your Stats
                VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                    Text("Your Stats")
                        .font(ClickTypography.titleSmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(ClickColors.textPrimary)

                    HStack(spacing: ClickSpacing.sm) {
                        HomeStatCard(
                            title: "Total Clicks",
                            value: snapshot.stats.totalClicks,
                            iconName: "person.2.circle.fill"
                        )
                        HomeStatCard(
                            title: "Encounters",
                            value: snapshot.stats.totalEncounters,
                            iconName: "mappin.circle.fill"
                        )
                        HomeStatCard(
                            title: "Circles",
                            value: snapshot.stats.totalCircles,
                            iconName: "circle.grid.3x3.fill"
                        )
                    }
                }
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.bottom, ClickSpacing.xxl)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .refreshable {
            // Simulated pull to refresh
            try? await Task.sleep(nanoseconds: 400_000_000)
            ClickHaptics.success()
        }
        .sheet(isPresented: $isSearching) {
            HomeSearchSheetView()
        }
    }

    private func toggleIntent(_ id: String) {
        if let idx = snapshot.intents.firstIndex(where: { $0.id == id }) {
            var updated = snapshot.intents
            updated[idx].isSelected.toggle()
            snapshot = HomeFeedSnapshot(
                greetingName: snapshot.greetingName,
                greetingSubtitle: snapshot.greetingSubtitle,
                intents: updated,
                featuredEvent: snapshot.featuredEvent,
                nearbyBeacons: snapshot.nearbyBeacons,
                recentConnections: snapshot.recentConnections,
                stats: snapshot.stats
            )
        }
    }
}

/// Simple modal search sheet for HomeSearchPill.
private struct HomeSearchSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: ClickSpacing.md) {
                HStack(spacing: ClickSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ClickColors.outline)
                    TextField("Search people, circles, places…", text: $query)
                        .font(ClickTypography.bodyMedium)
                }
                .padding(.horizontal, ClickSpacing.md)
                .padding(.vertical, 12)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                .overlay(
                    RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                )
                .padding(.horizontal, ClickSpacing.lg)
                .padding(.top, ClickSpacing.md)

                Spacer()

                VStack(spacing: ClickSpacing.xs) {
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 44))
                        .foregroundStyle(ClickColors.primary)
                    Text("Search Click Network")
                        .font(ClickTypography.titleMedium)
                        .fontWeight(.bold)
                    Text("Type a name, interest, beacon, or location to find connections.")
                        .font(ClickTypography.bodySmall)
                        .foregroundStyle(ClickColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, ClickSpacing.xl)
                }

                Spacer()
            }
            .background(ClickColors.background.ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(ClickTypography.labelLarge)
                    .foregroundStyle(ClickColors.primary)
                }
            }
        }
    }
}
