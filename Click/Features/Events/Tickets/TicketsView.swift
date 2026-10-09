import SwiftUI

/// Me → Tickets: every event you hold tickets for, upcoming or past. A row opens its passes.
struct TicketsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var scope: TicketScope = .upcoming
    @State private var groups: [TicketScope: [MyTicketsGroup]] = [:]
    @State private var loadError: String?

    /// Upcoming soonest first, past most recent first; undated events last.
    static func sections(_ groups: [MyTicketsGroup], scope: TicketScope) -> [MyTicketsGroup] {
        groups.sorted { a, b in
            switch (a.event.startAt, b.event.startAt) {
            case let (x?, y?): scope == .upcoming ? x < y : x > y
            case (.some, nil): true
            default: false
            }
        }
    }

    var body: some View {
        List {
            Picker("Tickets", selection: $scope) {
                Text("Upcoming").tag(TicketScope.upcoming)
                Text("Past").tag(TicketScope.past)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let items = groups[scope], !items.isEmpty {
                Section {
                    ForEach(Self.sections(items, scope: scope), id: \.event.beaconID) { group in
                        NavigationLink(value: AppRoute.eventPass(beaconID: group.event.beaconID)) {
                            TicketGroupRow(group: group)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { overlay }
        .navigationTitle("Tickets")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: seed)
        .task(id: scope) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private var overlay: some View {
        if let items = groups[scope] {
            if items.isEmpty {
                ContentUnavailableView(
                    scope == .upcoming ? "No tickets yet" : "No past tickets",
                    systemImage: "ticket",
                    description: Text(scope == .upcoming ? "Events you get tickets for show up here." : "Tickets for events that have ended show up here.")
                )
            }
        } else if let loadError {
            ContentUnavailableView {
                Label("Couldn’t load your tickets", systemImage: "exclamationmark.arrow.circlepath")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ClickLoadingView()
        }
    }

    private func seed() {
        for scope in [TicketScope.upcoming, .past] where groups[scope] == nil {
            groups[scope] = env.ticketing.cachedMyTickets(scope: scope)
        }
    }

    private func load() async {
        let scope = scope
        loadError = nil
        do {
            groups[scope] = try await env.ticketing.myTickets(scope: scope)
        } catch let error as TicketingError where error.isUnavailable {
            // Ticketing is off for this account: nothing to show, and Me stops offering it.
            groups[scope] = []
            await env.features.refresh()
        } catch {
            if !error.isCancellation, groups[scope] == nil { loadError = error.localizedDescription }
        }
    }
}

private struct TicketGroupRow: View {
    let group: MyTicketsGroup

    var body: some View {
        HStack(spacing: 14) {
            EventVisual(seed: group.event.visualSeed, imageURL: group.event.imageURL, symbol: "ticket")
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.event.title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(2)
                if let when {
                    Text(when)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if group.event.cancelled {
                        Text("Cancelled")
                            .font(ClickTypography.metadataEmphasized)
                            .foregroundStyle(ClickColors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(ClickColors.fillStrong, in: Capsule())
                            .fixedSize()
                    }
                    Text(summary)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// In the event's own time zone, like the event page.
    private var when: String? {
        guard let start = group.event.startAt else { return group.event.locationName }
        var style = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        if let id = group.event.timeZone, let zone = TimeZone(identifier: id) { style.timeZone = zone }
        let date = start.formatted(style)
        guard let place = group.event.locationName else { return date }
        return "\(date) · \(place)"
    }

    private var summary: String {
        let count = group.tickets.count
        let noun = count == 1 ? "ticket" : "tickets"
        let tiers = Set(group.tickets.map(\.tierName))
        guard tiers.count == 1, let tier = tiers.first else { return "\(count) \(noun)" }
        return "\(count) \(noun) · \(tier)"
    }
}
