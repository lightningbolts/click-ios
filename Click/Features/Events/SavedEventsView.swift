import SwiftUI

/// Saved Events (spec §65.7): server-backed bookmarks, hydrated from cache on cold start,
/// each row opening the canonical Event Detail.
struct SavedEventsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var events = ModuleState<[SavedEvent]>()

    var body: some View {
        List {
            if let items = events.value {
                OfflineNotice(showing: "saved events", hasCachedValue: true, refreshFailed: events.isStale) {
                    Task { await load() }
                }
                .listRowSeparator(.hidden)
                ForEach(sections(items), id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.events) { event in
                            Button {
                                env.router.navigate(to: .event(beaconID: event.beaconID))
                            } label: {
                                SavedEventRow(event: event)
                                    .padding(.horizontal, -18)
                            }
                            .buttonStyle(.plain)
                            .disabled(!event.isAvailable)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if let items = events.value, items.isEmpty {
                ContentUnavailableView(
                    "No saved events",
                    systemImage: "bookmark",
                    description: Text("Events you bookmark from Home or the map appear here.")
                )
            } else if events.value == nil {
                if let message = events.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load saved events", systemImage: "exclamationmark.arrow.circlepath")
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
        .navigationTitle("Saved events")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func sections(_ items: [SavedEvent]) -> [(title: String, events: [SavedEvent])] {
        let upcoming = items.filter { $0.isUpcomingOrLive() }
            .sorted { ($0.schedule?.start ?? .distantFuture) < ($1.schedule?.start ?? .distantFuture) }
        let past = items.filter { !$0.isUpcomingOrLive() }
        return [("Upcoming", upcoming), ("Past & unavailable", past)].filter { !$0.1.isEmpty }
    }

    private func load() async {
        guard let userID = env.session.currentSession?.userId else { return }
        events.seed(await env.beacons.cachedBookmarks(userID: userID))
        events.begin()
        do {
            events.succeed(try await env.beacons.bookmarks(userID: userID))
        } catch {
            events.fail(error)
        }
    }
}
