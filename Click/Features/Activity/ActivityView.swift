import SwiftUI

/// The Home bell's screen: every alert you got (events, drops, reactions, nudges, matches),
/// newest first, with friend requests to answer on top. It opens on the page the shell already
/// loaded and refreshes in place; a row opens exactly what its push would.
struct ActivityView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations

    /// The seen mark when this visit began: what's newer stays under "New" until you leave.
    @State private var visitMark: Date?
    @State private var visitStarted = false
    /// Requests being answered (their buttons show progress).
    @State private var responding: Set<String> = []
    @State private var notice: String?

    private var store: ActivityStore { env.activity }
    private var requests: [ConnectionItem] { conversations.active.filter(\.awaitsPriorResponse) }

    var body: some View {
        List {
            if store.feed.isStale {
                OfflineNotice(showing: "earlier activity", hasCachedValue: true, refreshFailed: true) {
                    Task { await store.refresh(force: true) }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !requests.isEmpty {
                Section("Friend requests") {
                    ForEach(requests) { item in
                        ActivityRequestRow(item: item, isResponding: responding.contains(item.id)) { accept in
                            respond(to: item, accept: accept)
                        }
                    }
                }
            }
            if store.feed.value != nil {
                ForEach(Self.sections(store.items, newerThan: visitStarted ? visitMark : store.seenAt), id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            ActivityRow(item: item)
                                .onAppear { if item.id == store.items.last?.id { Task { await store.loadMore() } } }
                        }
                    }
                }
                if store.feed.value?.nextBefore != nil {
                    Group {
                        if store.moreFailed {
                            Button("Couldn't load more. Retry") { Task { await store.loadMore() } }
                                .font(ClickTypography.supporting)
                        } else {
                            ClickLoadingView(size: 28, fillsSpace: false)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(ClickMotion.subtleFade, value: requests.map(\.id))
        .overlay { placeholder }
        .background(ClickColors.background)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .clickToast($notice)
        .refreshable {
            async let activity: Void = store.refresh(force: true)
            async let inbox: Void = conversations.refresh()
            _ = await (activity, inbox)
            store.markSeen()
        }
        .task {
            // Opened before the launch load finished: wait for it, so "New" uses the server's mark.
            if store.feed.value == nil { await store.refresh() }
            if !visitStarted {
                visitMark = store.seenAt
                visitStarted = true
            }
            store.markSeen()
            await store.refresh()
            store.markSeen()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if store.feed.value == nil, requests.isEmpty {
            if let message = store.feed.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load your activity", systemImage: "exclamationmark.arrow.circlepath")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.refresh(force: true) } }
                }
            } else {
                ClickLoadingView()
            }
        } else if store.feed.value != nil, store.items.isEmpty, requests.isEmpty {
            ContentUnavailableView {
                Label("No activity yet", systemImage: "bell")
            } description: {
                Text("New Clicks, reactions, RSVPs, friends’ plans, and events picking up near you show up here.")
            } actions: {
                Button("Find friends") { env.router.navigate(to: .findFriends) }
                    .buttonStyle(.clickSecondary)
                    .fixedSize()
            }
        }
    }

    private func respond(to item: ConnectionItem, accept: Bool) {
        guard !responding.contains(item.id) else { return }
        responding.insert(item.id)
        ClickHaptics.selection()
        Task {
            defer { responding.remove(item.id) }
            do {
                try await conversations.respondToPrior(item, accept: accept)
                if accept { notice = "You and \(item.displayName) are connected" }
            } catch {
                notice = error.userFacingMessage
            }
        }
    }

    // MARK: - Sections

    /// "New" (unseen when the visit began), then Today, Yesterday, This week, This month, Earlier.
    nonisolated static func sections(_ items: [ActivityItem], newerThan mark: Date?, now: Date = .now,
                                     calendar: Calendar = .current) -> [ActivitySection] {
        var out: [ActivitySection] = []
        for item in items {
            let title: String
            if ActivityStore.isNewer(item.createdAt, than: mark) {
                title = "New"
            } else if calendar.isDate(item.createdAt, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(item.createdAt, inSameDayAs: yesterday) {
                title = "Yesterday"
            } else if now.timeIntervalSince(item.createdAt) < 7 * 86_400 {
                title = "This week"
            } else if now.timeIntervalSince(item.createdAt) < 30 * 86_400 {
                title = "This month"
            } else {
                title = "Earlier"
            }
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append(ActivitySection(title: title, items: [item])) }
        }
        return out
    }

    /// "now", "5m", "3h", "2d", "4w".
    nonisolated static func age(_ date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return "\(days / 7)w"
    }
}

/// A run of activity under one header ("New", "Today", …).
struct ActivitySection: Equatable {
    let title: String
    var items: [ActivityItem]
}

/// One alert: who (or what) it's about, what happened, and when. Opens what its push opens.
private struct ActivityRow: View {
    let item: ActivityItem

    private var opens: Bool { ClickNotificationCoordinator.tapRoute(for: item.data) != .none }

    var body: some View {
        Button {
            Task { await ClickNotificationCoordinator.shared.openActivity(item) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ActivityGlyph(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.title)  \(Text(ActivityView.age(item.createdAt)).foregroundStyle(ClickColors.textTertiary))")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(3)
                    if !item.body.isEmpty {
                        Text(item.body)
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!opens)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.body)")
        .accessibilityValue(item.createdAt.formatted(.relative(presentation: .named)))
    }
}

/// The person's avatar with a small badge for what happened, or the badge alone when the
/// alert isn't about one person.
private struct ActivityGlyph: View {
    let item: ActivityItem

    var body: some View {
        let kind = ActivityKind(type: item.type)
        if let actor = item.actor {
            AvatarView(imageURL: actor.avatarURL, seed: actor.id, initials: Phase3Repository.initials(from: actor.name),
                       size: ActivityStore.avatarSize)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(kind.color, in: Circle())
                        .overlay { Circle().stroke(ClickColors.surface, lineWidth: 2) }
                        .offset(x: 4, y: 4)
                }
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(kind.color)
                .frame(width: ActivityStore.avatarSize, height: ActivityStore.avatarSize)
                .background(kind.color.opacity(0.14), in: Circle())
        }
    }
}

/// How an alert type looks: one symbol and one color per family.
struct ActivityKind: Equatable {
    let symbol: String
    let color: Color

    init(type: String) {
        switch type {
        case "reaction":
            (symbol, color) = ("heart.fill", .pink)
        case "event_rsvp":
            (symbol, color) = ("checkmark", ClickColors.success)
        case "event_rsvp_request":
            (symbol, color) = ("person.fill.questionmark", ClickColors.accentForeground)
        case "event_reminder", "event_teaser", "shared_upcoming_event":
            (symbol, color) = ("calendar", ClickColors.accentForeground)
        case "event_recap", "event_drop_recap", "shared_drop_released", "disposable_reveal", "memory_prompt":
            (symbol, color) = ("photo.on.rectangle.angled", ClickColors.accentForeground)
        case "availability_match", "hangout_confirm":
            (symbol, color) = ("hand.thumbsup.fill", ClickColors.success)
        case "wave":
            (symbol, color) = ("hand.wave.fill", ClickColors.warning)
        case "anniversary":
            (symbol, color) = ("gift.fill", ClickColors.warning)
        case "prior_connection_accepted", "new_connection":
            (symbol, color) = ("person.fill.checkmark", ClickColors.success)
        case "friends_going":
            (symbol, color) = ("person.2.fill", ClickColors.accentForeground)
        case "event_trending":
            (symbol, color) = ("flame.fill", .orange)
        case "archive_warning":
            (symbol, color) = ("archivebox.fill", ClickColors.warning)
        case "reconnect_nudge", "reconnect_lull", "reconnect_nearby", "group_revival":
            (symbol, color) = ("arrow.triangle.2.circlepath", ClickColors.accentForeground)
        default:
            (symbol, color) = ("bell.fill", ClickColors.accentForeground)
        }
    }
}

/// Someone found you through contacts and says you already know each other.
private struct ActivityRequestRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: ConnectionItem
    let isResponding: Bool
    let onRespond: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                env.router.navigate(to: .userProfile(userID: item.userID, connectionID: item.connectionID))
            } label: {
                HStack(spacing: 12) {
                    AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: ActivityStore.avatarSize)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)
                        Text("Says you know each other")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens their profile")

            if isResponding {
                ProgressView().frame(width: 72)
            } else {
                HStack(spacing: 8) {
                    Button("Ignore") { onRespond(false) }
                        .buttonStyle(ActivityPillStyle(prominent: false))
                    Button("Accept") { onRespond(true) }
                        .buttonStyle(ActivityPillStyle(prominent: true))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The compact in-row actions (Accept / Ignore): capsules sized to their text.
private struct ActivityPillStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClickTypography.metadataEmphasized)
            .foregroundStyle(prominent ? ClickColors.primaryActionForeground : ClickColors.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(prominent ? ClickColors.primaryActionFill : ClickColors.fillStrong, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(ClickMotion.press, value: configuration.isPressed)
    }
}

/// The Home toolbar's bell: a dot when there's unseen activity or a request waiting.
struct ActivityBellButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations

    private var hasNews: Bool {
        env.activity.hasUnseen || conversations.active.contains(where: \.awaitsPriorResponse)
    }

    var body: some View {
        Button {
            env.router.navigate(to: .activity)
        } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if hasNews {
                        Circle()
                            .fill(ClickColors.destructive)
                            .frame(width: 8, height: 8)
                            .offset(x: 1, y: -1)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(ClickMotion.subtleFade, value: hasNews)
        }
        .accessibilityLabel("Activity")
        .accessibilityValue(hasNews ? "New activity" : "")
    }
}
