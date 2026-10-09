import SwiftUI

/// What the viewer plays through, chapter by chapter.
enum StoryPlaylist: Hashable {
    /// The Home strip: a chapter per person (their drops, oldest first), in strip order.
    case people
    /// The archive: every drop its own chapter, in grid order.
    case archive
}

/// Shared Click Drops in the story viewer. A ready drop develops as it opens, unveiling from its
/// pixels. Replies and reactions go to your chat with the poster and carry the drop with them;
/// your own drops show who reacted instead.
@Observable
@MainActor
final class SharedDropStorySource: DropStorySource {
    private let env: AppEnvironment
    private let playlist: StoryPlaylist
    /// The people, and each one's drops, as they were when the viewer opened: Home's day of drops
    /// rolls on and refreshes underneath, but what plays next never changes while you watch.
    private let peopleOrder: [String]
    private let peopleDrops: [String: [String]]
    /// The reply being typed on the current page.
    var reply = ""

    init(env: AppEnvironment, playlist: StoryPlaylist) {
        self.env = env
        self.playlist = playlist
        let groups = playlist == .people ? env.sharedDropsStore.groups : []
        peopleOrder = groups.map(\.userID)
        peopleDrops = Dictionary(uniqueKeysWithValues: groups.map { ($0.userID, $0.drops.map(\.id)) })
    }

    private var store: SharedDropsStore { env.sharedDropsStore }

    // MARK: - Chapters

    var chapterKeys: [String] {
        switch playlist {
        case .people: peopleOrder
        // Append-only as pages load, so it's read live.
        case .archive: archiveIDs
        }
    }

    private var archiveIDs: [String] { (store.archive.value?.drops ?? []).map(\.id) }

    func chapterKey(of id: String) -> String? {
        guard let drop = store.drop(id) else { return nil }
        return playlist == .people ? drop.userID : drop.id
    }

    func chapter(_ key: String) -> [String] {
        switch playlist {
        case .people: person(key)?.drops.map(\.id) ?? []
        case .archive: store.drop(key).map { [$0.id] } ?? []
        }
    }

    func chapterStart(_ key: String) -> String? {
        switch playlist {
        case .people: person(key)?.start.id
        case .archive: chapter(key).first
        }
    }

    var nextChapterLabel: String { playlist == .people ? "Next person" : "Next drop" }

    /// A person's stack as it was when the viewer opened, each drop read live (a develop shows).
    private func person(_ key: String) -> SharedDropGroup? {
        let drops = (peopleDrops[key] ?? []).compactMap(store.drop)
        return drops.isEmpty ? nil : SharedDropGroup(userID: key, drops: drops)
    }

    // MARK: - Pages

    func page(_ id: String) -> DropStoryPage? {
        guard let drop = store.drop(id) else { return nil }
        return DropStoryPage(id: drop.id, userID: drop.userID, userName: drop.userName, avatarURL: drop.avatarURL,
                             isMine: drop.isMine, previewURL: drop.previewURL, subtitle: subtitle(drop), caption: drop.caption)
    }

    private func subtitle(_ drop: SharedDrop) -> String? {
        guard let created = drop.createdAt else { return nil }
        let when = created.formatted(.relative(presentation: .named))
        guard drop.isMine, let audience = drop.audience else { return when }
        return when + (audience == .core ? " · Core connections" : " · All connections")
    }

    func isDeveloped(_ id: String) -> Bool { store.drop(id)?.state() == .developed }

    func developsAt(_ id: String) -> Date? {
        if case .pending(let reveal) = store.drop(id)?.state() { reveal } else { nil }
    }

    func status(_ id: String) -> (title: String, systemImage: String) {
        if let reveal = developsAt(id) { return ("Develops \(reveal.formatted(.relative(presentation: .named)))", "hourglass") }
        return (store.developing.contains(id) || store.drop(id)?.state() == .ready ? "Developing…" : "Opening…", "sparkles")
    }

    /// A ready drop develops the moment it's seen; a pending one waits on screen for its time
    /// (nothing is asked of the server before then), then develops the same way.
    func open(_ id: String) async {
        if let reveal = developsAt(id) {
            // Just past the reveal, like the strip's live develop, so the server agrees it's time.
            try? await Task.sleep(for: .seconds(max(0, reveal.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
        }
        if let drop = store.drop(id), drop.state() == .ready { await store.develop([drop], fresh: true, env: env) }
    }

    /// Near the end of what the archive has loaded, its next page follows.
    func prepare(_ ids: [String]) {
        let loaded = archiveIDs
        guard playlist == .archive, let id = ids.first,
              let index = loaded.firstIndex(of: id), index >= loaded.count - 5 else { return }
        Task { await store.loadMoreArchive(env: env) }
    }

    func tapDevelops(_ id: String) -> Bool { false }
    func develop(_ id: String) async {}

    // MARK: - Photos

    /// The strip tile's copy, else the archive grid's.
    func cachedPhoto(_ id: String) -> UIImage? { store.originals[id] ?? store.thumbs[id] }

    func fullPhoto(_ id: String) async -> UIImage? {
        guard let drop = store.drop(id) else { return nil }
        return await store.fullImage(for: drop, env: env)
    }

    func image(_ photo: UIImage) -> UIImage { photo }

    func isSaved(_ id: String) -> Bool {
        env.session.currentSession.map { DropPhotoCache.exists(id, userID: $0.userId) } ?? false
    }

    func isFresh(_ id: String) -> Bool { store.freshlyDeveloped.contains(id) }
    func consumeFresh(_ id: String) -> Bool { store.freshlyDeveloped.remove(id) != nil }

    // MARK: - Delete and report

    var deleteMessage: String { "It's removed for everyone it was shared with." }

    func delete(_ id: String) async throws {
        try await env.drops.deleteSharedDrop(id: id)
        store.remove(id, env: env)
    }

    func report(_ id: String, reason: String) async throws {
        try await env.beacons.reportDrop(ClickDropRef(kind: .shared, id: id), reason: reason)
    }

    // MARK: - Footer

    func footer(_ id: String, live: Bool, shown: Bool, interaction: DropStoryInteraction) -> some View {
        SharedDropFooter(source: self, drop: store.drop(id), live: live, shown: shown, interaction: interaction)
    }

    /// Into the 1-1 chat with the poster, through the same optimistic pipeline as any message, so
    /// it's already there when that chat opens.
    fileprivate func send(_ text: String, about drop: SharedDrop, reaction: Bool) -> String? {
        guard let connectionID = drop.connectionID else { return nil }
        let route = DirectChatRoute(connectionID: connectionID, peerUserID: drop.userID,
                                    peerDisplayName: drop.userName, peerAvatarURL: drop.avatarURL)
        let model = env.conversationModel(for: route.conversationIdentity)
        Task { await model.sendDropReply(text, to: ChatDropReply(dropID: drop.id, isReaction: reaction)) }
        ClickHaptics.success()
        let first = Self.firstName(drop)
        return reaction ? "Reaction sent to \(first)" : "Sent to \(first)"
    }

    fileprivate static func firstName(_ drop: SharedDrop) -> String {
        drop.userName.split(separator: " ").first.map(String.init) ?? drop.userName
    }
}

/// The reactions sit still from the first frame: no fade while the viewer zooms open or the
/// photo develops (Liquid Glass flickers under a changing opacity). Every drop reserves the
/// same footer, the palette over a one-line reply, whatever it shows (your own drop's
/// reactors, a drop with no chat to reply in, reactions arriving), so the photo above it sits
/// in one place on every page; the bar grows up over the photo as a reply wraps. The palette
/// steps aside while you type a reply.
private struct SharedDropFooter: View {
    @Bindable var source: SharedDropStorySource
    let drop: SharedDrop?
    let live: Bool
    let shown: Bool
    @Bindable var interaction: DropStoryInteraction
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: ReactionBar<EmptyView>.trayHeight)
            Text(" ").font(ClickTypography.body).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .hidden()
        .overlay(alignment: .bottom) {
            if let drop {
                ReactionBar(target: .sharedDrop, id: drop.id, isOwner: drop.isMine, presenting: $interaction.presenting,
                            reactable: shown, composing: live && interaction.composing) { emoji in
                    interaction.toast = source.send(emoji, about: drop, reaction: true)
                } accessory: {
                    // A reply carries the drop into the chat, which shows its photo: only once it's
                    // developed, never asking for it early.
                    if !drop.isMine, drop.connectionID != nil, !drop.state().isPending {
                        replyField(drop)
                    }
                }
                .id(drop.id)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 10)
        .padding(.horizontal, 14)
        .onChange(of: focused) { _, focused in if live { interaction.composing = focused } }
        .onChange(of: interaction.composing) { _, composing in if !composing { focused = false } }
    }

    /// The incoming face's field is the same view with no text, so nothing changes as it lands.
    private func replyField(_ drop: SharedDrop) -> some View {
        let trimmed = live ? source.reply.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return HStack(spacing: 10) {
            TextField("Reply to \(SharedDropStorySource.firstName(drop))…", text: live ? $source.reply : .constant(""), axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { sendReply(drop) }
                .font(ClickTypography.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1))
            if !trimmed.isEmpty {
                Button { sendReply(drop) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(ClickColors.primaryActionForeground)
                        .frame(width: 44, height: 44)
                        .glassCircleBackground(tint: ClickColors.primaryActionFill)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send reply")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .animation(ClickMotion.press, value: trimmed.isEmpty)
    }

    private func sendReply(_ drop: SharedDrop) {
        let text = source.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        source.reply = ""
        interaction.composing = false
        interaction.toast = source.send(text, about: drop, reaction: false)
    }
}

extension View {
    /// Presents shared drops' story viewer, which runs its own zoom, in a window over this one.
    func dropViewer(_ viewing: Binding<SharedDropsStrip.ViewerStart?>, sources: DropTileFrames) -> some View {
        modifier(SharedDropViewerPresentation(viewing: viewing, sources: sources))
    }
}

extension SharedDropsStrip.ViewerStart {
    static func open(_ id: String, playlist: StoryPlaylist = .people, in viewing: Binding<SharedDropsStrip.ViewerStart?>) {
        viewing.wrappedValue = .init(id: id, playlist: playlist)
    }
}

private struct SharedDropViewerPresentation: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var viewing: SharedDropsStrip.ViewerStart?
    let sources: DropTileFrames

    func body(content: Content) -> some View {
        content.dropStory($viewing) { start in
            DropStoryViewer(source: SharedDropStorySource(env: env, playlist: start.playlist), startID: start.id, sources: sources)
        }
    }
}
