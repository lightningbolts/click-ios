import SwiftUI

/// Everything you've done on Click, in one private place (replaces Saved events): events you were
/// part of, beacons you dropped / reacted to / confirmed, hangouts you logged, and your saved events.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var filter: HistoryFilter = .all
    @State private var items = ModuleState<[HistoryItem]>()
    @State private var nextCursor: String?
    @State private var isLoadingMore = false

    var body: some View {
        Group {
            if filter == .saved {
                SavedEventsView(inHistory: true)
            } else {
                list
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(HistoryFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.vertical, 8)
            .background(ClickColors.background)
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var list: some View {
        List {
            if let rows = items.value {
                ForEach(sections(rows), id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            HistoryRow(item: item)
                                .onAppear { if item.id == rows.last?.id { Task { await loadMore() } } }
                        }
                    }
                }
                if isLoadingMore { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if let rows = items.value, rows.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "clock",
                                       description: Text(emptyText))
            } else if items.value == nil {
                if let message = items.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load your history", systemImage: "exclamationmark.arrow.circlepath")
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
        .task(id: filter) { await load() }
        .refreshable { await load() }
    }

    private var emptyText: String {
        switch filter {
        case .events: "Events you go to, RSVP to, save, or host show up here after they end."
        case .beacons: "Beacons you drop, react to, or confirm show up here."
        case .hangouts: "Hangouts you log with your Clicks show up here."
        case .all, .saved: "Events, beacons, and hangouts you're part of show up here."
        }
    }

    /// Month headers keep a long history scannable without turning it into a feed.
    private func sections(_ rows: [HistoryItem]) -> [(title: String, items: [HistoryItem])] {
        var out: [(title: String, items: [HistoryItem])] = []
        for item in rows {
            let title = item.at?.formatted(.dateTime.month(.wide).year()) ?? "Earlier"
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    private func load() async {
        items.begin()
        do {
            let page = try await env.beacons.history(filter, cursor: nil)
            items.succeed(page.items)
            nextCursor = page.nextCursor
        } catch {
            if !error.isCancellation { items.fail(error.userFacingMessage) }
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, let current = items.value else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await env.beacons.history(filter, cursor: cursor) else { return }
        items.succeed(current + page.items.filter { new in !current.contains { $0.id == new.id } })
        nextCursor = page.nextCursor
    }
}

/// One History entry: what it was, how you were part of it, and where it opens.
private struct HistoryRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: HistoryItem

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                leading.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(ClickTypography.bodyEmphasized).foregroundStyle(ClickColors.textPrimary).lineLimit(1)
                    Text(subtitle).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.recap != nil {
                    Button {
                        env.router.navigate(to: .eventRecap(beaconID: item.id))
                    } label: {
                        Image(systemName: item.recap == .ready ? "sparkles" : "hourglass")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(ClickColors.fillSubtle, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ClickColors.accentForeground)
                    .accessibilityLabel(item.recap == .ready ? "Open recap" : "Recap developing")
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .hangout:
            AvatarView(imageURL: item.peerAvatarURL, seed: item.peerID ?? item.id,
                       initials: Phase3Repository.initials(from: item.peerName ?? "?"), size: 44)
        case .event, .beacon:
            EventVisual(seed: item.beaconID ?? item.id, imageURL: item.imageURL,
                        symbol: item.kind == .event ? "calendar" : BeaconKind(raw: item.beaconType).systemImage, cornerRadius: 12)
        }
    }

    private var subtitle: String {
        [item.detail, item.at?.formatted(.dateTime.month(.abbreviated).day()), item.place]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func open() {
        switch item.kind {
        case .event: env.router.navigate(to: .event(beaconID: item.id))
        case .beacon: env.router.navigate(to: .beacon(beaconID: item.id))
        case .hangout:
            if let peer = item.peerID { env.router.navigate(to: .userProfile(userID: peer, connectionID: item.connectionID)) }
        }
    }
}
