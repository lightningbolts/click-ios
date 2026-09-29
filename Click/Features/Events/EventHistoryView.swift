import SwiftUI

/// Past events (spec F2): private to you, filtered by how you took part. Each opens the event, and
/// its recap when there is one. Past events never appear on Home beyond the 48-hour recap card.
struct EventHistoryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var filter: EventHistoryFilter = .all
    @State private var events = ModuleState<[PastEvent]>()
    @State private var nextCursor: String?
    @State private var isLoadingMore = false

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(EventHistoryFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let items = events.value {
                ForEach(items) { event in
                    PastEventRow(event: event)
                        .onAppear {
                            if event.id == items.last?.id { Task { await loadMore() } }
                        }
                }
                if isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if let items = events.value, items.isEmpty {
                ContentUnavailableView("No past events", systemImage: "calendar",
                                       description: Text("Events you go to, RSVP to, save, or host show up here after they end."))
            } else if events.value == nil {
                if let message = events.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load past events", systemImage: "exclamationmark.arrow.circlepath")
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
        .navigationTitle("Past events")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        events.begin()
        do {
            let page = try await env.beacons.eventHistory(filter: filter, cursor: nil)
            events.succeed(page.events)
            nextCursor = page.nextCursor
        } catch {
            if !error.isCancellation { events.fail(error.userFacingMessage) }
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, let current = events.value else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await env.beacons.eventHistory(filter: filter, cursor: cursor) else { return }
        events.succeed(current + page.events.filter { new in !current.contains { $0.id == new.id } })
        nextCursor = page.nextCursor
    }
}

/// One past event: when, where, how you took part, and its recap when there is one.
struct PastEventRow: View {
    @Environment(AppEnvironment.self) private var env
    let event: PastEvent

    var body: some View {
        Button {
            env.router.navigate(to: .event(beaconID: event.beaconID))
        } label: {
            HStack(spacing: 12) {
                EventVisual(seed: event.beaconID, imageURL: event.imageURL, symbol: "calendar", cornerRadius: 12)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(ClickTypography.bodyEmphasized).foregroundStyle(ClickColors.textPrimary).lineLimit(1)
                    Text(subtitle).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let recap = event.recap {
                    Button {
                        env.router.navigate(to: .eventRecap(beaconID: event.beaconID))
                    } label: {
                        Label(recap == .ready ? "Recap" : "Developing", systemImage: recap == .ready ? "sparkles" : "hourglass")
                            .font(ClickTypography.metadataEmphasized)
                    }
                    .buttonStyle(.bordered)
                    .tint(ClickColors.accentForeground)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let ends = event.endsAt { parts.append(ends.formatted(date: .abbreviated, time: .omitted)) }
        if let relation = event.relation {
            if relation.hosted { parts.append("Hosted") } else if relation.went { parts.append("Went") }
            else if relation.rsvpd { parts.append("RSVP'd") } else if relation.saved { parts.append("Saved") }
        }
        if let place = event.locationName { parts.append(place) }
        return parts.joined(separator: " · ")
    }
}
