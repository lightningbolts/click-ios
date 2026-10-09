import SwiftUI

/// Home's "View all": every shared Click Drop you can see, newest first, in a photo grid under
/// day headers (like Activity), including the ones Home leaves out (past a day, or past
/// someone's newest five). It opens on the first page the strip already loaded behind it,
/// tiles decode a few rows ahead of the scroll, and a tile opens the story viewer, which plays on
/// through the archive in grid order.
struct SharedDropsArchiveView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var viewing: SharedDropsStrip.ViewerStart?
    @State private var tileFrames = DropTileFrames()
    /// Bumped when the next pending drop develops, so its tile turns ready on time.
    @State private var tick = 0

    private var store: SharedDropsStore { env.sharedDropsStore }
    private var drops: [SharedDrop] { store.archive.value?.drops ?? [] }

    private static let spacing: CGFloat = 4
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    var body: some View {
        ScrollView {
            // Headers scroll with the photos, like Activity's: pinned, they'd need an opaque band
            // under the translucent navigation bar.
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
                ForEach(Self.sections(drops), id: \.title) { section in
                    Section {
                        ForEach(section.drops) { drop in
                            tile(drop)
                                .onAppear { appeared(drop) }
                        }
                    } header: {
                        Text(section.title)
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.top, 12)
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .padding(.horizontal, 12)
            .animation(ClickMotion.subtleFade, value: drops.map(\.id))
            footer
        }
        .overlay { placeholder }
        .background(ClickColors.background)
        .navigationTitle("Click Drops")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.loadArchive(env: env, force: true) }
        .task { await store.loadArchive(env: env) }
        .task(id: nextReveal) {
            guard let next = nextReveal else { return }
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.5))
            if !Task.isCancelled { tick += 1 }
        }
        .dropViewer($viewing, sources: tileFrames)
    }

    private var nextReveal: Date? {
        _ = tick
        return drops.compactMap { $0.state().isPending ? $0.revealAt : nil }.min()
    }

    /// Paging and photo prefetch follow the scroll: the next page starts loading two screens
    /// before the end, and photos a few rows ahead.
    private func appeared(_ drop: SharedDrop) {
        guard let index = drops.firstIndex(where: { $0.id == drop.id }) else { return }
        store.prefetchThumbs(after: index, env: env)
        if index >= drops.count - 18 { Task { await store.loadMoreArchive(env: env) } }
    }

    @ViewBuilder
    private var footer: some View {
        if store.archive.value?.nextBefore != nil {
            Group {
                if store.archiveMoreFailed {
                    Button("Couldn't load more. Retry") { Task { await store.loadMoreArchive(env: env) } }
                        .font(ClickTypography.supporting)
                } else {
                    ClickLoadingView(size: 28, fillsSpace: false)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if store.archive.value == nil {
            if let message = store.archive.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load your drops", systemImage: "exclamationmark.arrow.circlepath")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.loadArchive(env: env, force: true) } }
                }
            } else {
                ClickLoadingView()
            }
        } else if drops.isEmpty {
            ContentUnavailableView {
                Label("No drops yet", systemImage: "camera")
            } description: {
                Text("Drops you and your connections share show up here, older ones included.")
            }
        }
    }

    // MARK: - Tiles

    private func tile(_ drop: SharedDrop) -> some View {
        let state = drop.state()
        let photo = store.thumbs[drop.id] ?? store.originals[drop.id]
        return Button {
            if !state.isPending { SharedDropsStrip.ViewerStart.open(drop.id, playlist: .archive, in: $viewing) }
        } label: {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if state == .developed, let photo {
                        Image(uiImage: photo).resizable().scaledToFill().transition(.opacity)
                    } else {
                        PixelatedPreview(url: drop.previewURL).shimmering(store.developing.contains(drop.id))
                    }
                }
                .overlay(alignment: .topTrailing) { badge(state).padding(5) }
                .overlay(alignment: .bottomLeading) {
                    AvatarView(imageURL: drop.avatarURL, seed: drop.userID, initials: Phase3Repository.initials(from: drop.userName), size: 22)
                        .padding(2)
                        .glassCircleBackground()
                        .padding(5)
                }
                .overlay {
                    if state == .ready {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ClickColors.accentForeground, lineWidth: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .environment(\.colorScheme, .dark)
                .animation(ClickMotion.reveal, value: photo != nil)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .dropTileSource(drop.id, in: tileFrames)
        }
        .buttonStyle(.plain)
        .disabled(state.isPending)
        .task(id: state == .developed) { await store.loadThumb(drop, env: env) }
        .accessibilityLabel(accessibility(drop, state: state))
    }

    @ViewBuilder
    private func badge(_ state: ClickDropDevelopState) -> some View {
        switch state {
        case .pending(let reveal):
            Label(SharedDropsStrip.shortCountdown(to: reveal), systemImage: "hourglass")
                .labelStyle(.titleAndIcon)
                .font(ClickTypography.badge.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .glassCircleBackground()
        case .ready:
            Image(systemName: "sparkles")
                .font(ClickTypography.badge)
                .foregroundStyle(.white)
                .padding(5)
                .glassCircleBackground(tint: ClickColors.primaryActionFill)
        case .developed:
            EmptyView()
        }
    }

    private func accessibility(_ drop: SharedDrop, state: ClickDropDevelopState) -> String {
        let who = drop.isMine ? "Your drop" : "Drop from \(drop.userName)"
        let when = drop.createdAt.map { ", \($0.formatted(.relative(presentation: .named)))" } ?? ""
        switch state {
        case .pending(let reveal): return "\(who)\(when), develops \(reveal.formatted(.relative(presentation: .named)))"
        case .ready: return "\(who)\(when), ready to develop. Opens it."
        case .developed: return "\(who)\(when). Opens it."
        }
    }

    // MARK: - Sections

    struct DaySection: Equatable {
        let title: String
        var drops: [SharedDrop]
    }

    /// Today, Yesterday, This week, This month, then a header per month ("August 2026").
    nonisolated static func sections(_ drops: [SharedDrop], now: Date = .now, calendar: Calendar = .current) -> [DaySection] {
        var out: [DaySection] = []
        for drop in drops {
            let date = drop.createdAt ?? now
            let title: String
            if calendar.isDate(date, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                title = "Yesterday"
            } else if now.timeIntervalSince(date) < 7 * 86_400 {
                title = "This week"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .month) {
                title = "This month"
            } else {
                title = date.formatted(.dateTime.month(.wide).year())
            }
            if out.last?.title == title { out[out.count - 1].drops.append(drop) } else { out.append(DaySection(title: title, drops: [drop])) }
        }
        return out
    }
}
