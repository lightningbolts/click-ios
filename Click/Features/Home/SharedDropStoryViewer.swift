import SwiftUI

/// What the viewer plays through, chapter by chapter.
enum StoryPlaylist: Hashable {
    /// The Home strip: a chapter per person (their drops, oldest first), in strip order.
    case people
    /// The archive: every drop its own chapter, in grid order.
    case archive
}

/// Shared Click Drops, Instagram-story style: zooms out of the tapped tile, then one drop after
/// another with progress segments for the current person; past their last drop it carries on to
/// the next person. Tap the sides to move, swipe sideways to turn (a cube, like Instagram) to the next or previous person, hold to pause, swipe down to close. A ready drop develops right
/// here, unveiling from its pixels. Replies and reactions go to your chat with the poster and
/// carry the drop with them; your own drops show who reacted instead.
struct SharedDropStoryViewer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.closeDropViewer) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentID: String
    /// Ticks in its own view (the progress bar), so the viewer doesn't re-render while a drop plays.
    @State private var clock = StoryClock()
    @State private var holding = false
    @State private var pressStart: Date?
    @State private var reply = ""
    /// The reply field being typed in, by drop (only the current page's field can take focus).
    @FocusState private var focusedReply: String?
    private var replyFocused: Bool { focusedReply != nil }
    /// Full-size photos for this viewing (tiles keep small copies).
    @State private var full: [String: UIImage] = [:]
    @State private var unveiled: Set<String> = []
    /// Developed on this screen just now: they play the develop when they unveil.
    @State private var playing: Set<String> = []
    @State private var dragY: CGFloat = 0
    @State private var toast: String?
    @State private var confirmDelete = false
    @State private var reporting = false
    /// False while zoomed into the source tile: before the open, and while closing.
    @State private var presented = false
    /// The card cross-fading with its tile while it's tile-sized: in as the zoom starts, out as it
    /// lands, so the tile's own glass (name, avatar, stack count) fades instead of popping.
    @State private var cardOpacity: Double = 0
    /// The caption's glass pill sits out the cross-fade (glass flickers under a changing opacity).
    @State private var captionHidden = true
    @State private var frame: CGRect = .zero
    @State private var insets = EdgeInsets()
    /// Each drop's shape (width over height), from its photo or, before that, its preview.
    @State private var aspects: [String: CGFloat] = [:]
    /// The header's and each kind of footer's height (see `footerKind`): the photo sits in the
    /// space between them, and the next person's page lays out the same before it's measured.
    @State private var chromeHeights: [String: CGFloat] = [:]
    /// The sideways turn between people, Instagram's cube: the drag (or turn) offset, observed only
    /// by the two faces so a drag doesn't re-render the viewer.
    @State private var cube = CubeTurn()
    /// The person's page on the cube's other face while dragging or turning: which way, and the
    /// drop it opens on (nil past the first or last person).
    @State private var cubeSide: CubeSide?
    /// Finishing a turn or springing back: gestures and the timer wait for it.
    @State private var cubeSettling = false
    @State private var dragAxis: Axis?
    /// The progress bar on the incoming face: its current segment sits empty.
    @State private var idleClock = StoryClock()
    /// The people in the order they were when the viewer opened, so watching (which can move a
    /// tile) never changes what comes next.
    @State private var peopleOrder: [String]?
    private let sources: DropTileFrames?
    private let playlist: StoryPlaylist

    private static let secondsPerDrop: Double = 6
    /// Your own drop's reactor row (a face, its emoji and a name), held while reactions load.
    private static let reactorRowHeight: CGFloat = 68
    /// The gap between the photo and the header above it or the reactions below.
    private static let photoGap: CGFloat = 8
    /// Quicker than the system zoom, so a drop feels like it pops open. A curve rather than a
    /// spring, so it lands on time: by `zoomSettled` it's within a few points of the tile, and
    /// the card can fade over it without ghosting.
    private static let zoom = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.2)
    private static let zoomSettled = 0.14
    /// The cube finishing a turn (or springing back): quick, no overshoot.
    private static let cubeAnimation = Animation.snappy(duration: 0.32)
    /// The card and its tile trading places at either end of the zoom: quick on the way out of
    /// the tile, before the card has grown enough to show the screen through it.
    private static let crossFadeIn = Animation.easeOut(duration: 0.06)
    private static let crossFade = Animation.easeInOut(duration: 0.1)

    /// Present with animations disabled: the viewer runs its own zoom out of `sources`' tile
    /// (or a fade without one, or under Reduce Motion).
    init(startID: String, playlist: StoryPlaylist = .people, sources: DropTileFrames? = nil) {
        _currentID = State(initialValue: startID)
        self.playlist = playlist
        self.sources = sources
    }

    private var store: SharedDropsStore { env.sharedDropsStore }

    // MARK: - Chapters

    private var chapterKeys: [String] {
        switch playlist {
        case .people: peopleOrder ?? store.groups.map(\.userID)
        // Append-only as pages load, so it's read live.
        case .archive: store.archiveViewable.map(\.id)
        }
    }

    private func chapterKey(_ drop: SharedDrop) -> String {
        playlist == .people ? drop.userID : drop.id
    }

    /// A chapter's drops that can be opened, in play order.
    private func chapter(_ key: String) -> [SharedDrop] {
        switch playlist {
        case .people: store.group(key)?.viewable ?? []
        case .archive: store.drop(key).map { $0.state().isPending ? [] : [$0] } ?? []
        }
    }

    private func chapterStart(_ key: String) -> String? {
        switch playlist {
        case .people: store.group(key)?.start?.id
        case .archive: chapter(key).first?.id
        }
    }

    /// The current chapter: what the progress bar shows and taps move through.
    private var sequence: [SharedDrop] { current.map { chapter(chapterKey($0)) } ?? [] }

    /// The drops that play after `id`, across chapters, for prefetching.
    private func upcoming(after id: String, count: Int) -> [SharedDrop] {
        guard let drop = store.drop(id) else { return [] }
        let key = chapterKey(drop)
        let here = chapter(key)
        var out = Array(here.drop { $0.id != id }.dropFirst().prefix(count))
        let keys = chapterKeys
        var index = (keys.firstIndex(of: key) ?? keys.count) + 1
        while out.count < count, keys.indices.contains(index) {
            let next = chapter(keys[index])
            let start = chapterStart(keys[index])
            out += next.drop { $0.id != start }.prefix(count - out.count)
            index += 1
        }
        return out
    }
    private var current: SharedDrop? { store.drop(currentID) }
    private func photo(_ id: String) -> UIImage? { full[id] ?? store.originals[id] }
    /// A photo already on hand (and not just developed) shows from the first frame, so nothing
    /// swaps in while the viewer is still zooming open.
    private func isShown(_ id: String) -> Bool {
        unveiled.contains(id) || (photo(id) != nil && !store.freshlyDeveloped.contains(id))
    }
    private func playsDevelop(_ id: String) -> Bool {
        !reduceMotion && (playing.contains(id) || store.freshlyDeveloped.contains(id))
    }
    private var isPaused: Bool {
        holding || replyFocused || confirmDelete || reporting || cubeSide != nil || !isShown(currentID)
    }

    var body: some View {
        ZStack {
            // Home dims to black behind the zooming card, so the card's growing edge never wipes
            // across the tab bar. Plain black, no glass, so it can fade; it lifts as you drag.
            Color.black.ignoresSafeArea()
                .opacity(presented ? Double(1 - min(dragY, 240) / 240) : 0)
            card
        }
        // Our own swipe-down (which also pauses) closes, zooming back into the tile.
        .simultaneousGesture(dismissDrag)
        .task {
            // Zoom once the viewer has been laid out over its tile, so it never fades in.
            for _ in 0..<20 where frame == .zero {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await Task.yield()
            captionHidden = false
            withAnimation(Self.zoom) { presented = true }
            withAnimation(Self.crossFadeIn) { cardOpacity = 1 }
        }
        .environment(\.colorScheme, .dark)
        // Follows the zoom, so the status bar fades back as the card shrinks, not after.
        .statusBarHidden(presented)
        .clickToast($toast, edge: .top)
        .task(id: currentID) { await open(currentID) }
        .onAppear { if playlist == .people, peopleOrder == nil { peopleOrder = store.groups.map(\.userID) } }
        .task(id: "\(currentID)|\(isPaused)") { await runTimer() }
        .onChange(of: current == nil) { _, gone in if gone { close() } }
        .confirmation("Delete this drop?", isPresented: $confirmDelete, keep: "Keep It",
                      message: "It's removed for everyone it was shared with.") {
            Button("Delete", role: .destructive) { Task { await delete() } }
        }
        .confirmationDialog("Report this photo?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["Inappropriate", "Harassment", "Spam"], id: \.self) { reason in
                Button(reason) { Task { await report(reason) } }
            }
        } message: {
            Text("Reports go quietly to the Click team. Nobody else sees them.")
        }
    }

    /// The viewer itself: opaque, zoomed out of and back into the tile.
    private var card: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Keyed by drop, so the incoming face becomes the current page as is when a turn lands:
            // nothing reloads, re-lays out or fades.
            ForEach(faces, id: \.drop.id) { face in
                CubeFace(cube: cube, base: face.base, width: frame.width) {
                    page(face.drop, live: face.drop.id == currentID)
                }
            }
        }
        .offset(y: dragY)
        .scaleEffect(1 - min(dragY, 400) / 2400)
        // Zooming, the viewer stays opaque and is cropped to the tile's shape instead of fading:
        // Liquid Glass (the header, caption and reactions) flickers under a changing opacity.
        .clipShape(crop)
        .scaleEffect(collapsed?.scale ?? 1)
        .offset(collapsed?.offset ?? .zero)
        .opacity(presented || collapsed != nil ? cardOpacity : 0)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
        .onGeometryChange(for: EdgeInsets.self, of: { $0.safeAreaInsets }) { insets = $0 }
    }

    /// The current page, and the next (or previous) person's on the cube's other face.
    private var faces: [(drop: SharedDrop, base: CGFloat)] {
        guard let drop = current else { return [] }
        var out: [(drop: SharedDrop, base: CGFloat)] = []
        for (step, id) in sideFaces {
            if id != currentID, let other = store.drop(id) { out.append((other, CGFloat(step))) }
        }
        return out + [(drop, 0)]
    }

    /// The faces beside the current one. Mid-turn, the one being turned to; otherwise, at either
    /// end of a person's story, whoever a tap or the timer would turn to, mounted edge-on out of
    /// sight so the turn animates a face that already exists (one inserted mid-animation would
    /// just appear at its end).
    private var sideFaces: [(step: Int, id: String)] {
        if let side = cubeSide { return side.id.map { [(side.step, $0)] } ?? [] }
        let ids = sequence.map(\.id)
        var out: [(step: Int, id: String)] = []
        if ids.first == currentID, let id = chapterNeighbor(-1) { out.append((-1, id)) }
        if ids.last == currentID, let id = chapterNeighbor(1) { out.append((1, id)) }
        return out
    }

    /// One drop's page: the photo between its header and reactions. Only the current page takes
    /// touches and measures; the incoming one is a still copy.
    private func page(_ drop: SharedDrop, live: Bool) -> some View {
        ZStack {
            photoLayer(drop, live: live)
                .ignoresSafeArea(.keyboard)
            VStack(spacing: 0) {
                header(drop, live: live)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured("header", $0, live: live) }
                Spacer(minLength: 0)
                footer(drop, live: live)
                    // Held while typing, so a growing reply never shrinks the photo.
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if !replyFocused { measured(footerKind(drop), $0, live: live) } }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .allowsHitTesting(live)
        .accessibilityHidden(!live)
    }

    private func footerKind(_ drop: SharedDrop) -> String {
        drop.isMine ? "mine" : drop.connectionID != nil ? "reply" : "plain"
    }

    private func measured(_ key: String, _ height: CGFloat, live: Bool) {
        guard live || chromeHeights[key] == nil, chromeHeights[key] != height else { return }
        chromeHeights[key] = height
    }

    private var headerHeight: CGFloat { chromeHeights["header"] ?? 0 }
    private func footerHeight(_ drop: SharedDrop?) -> CGFloat {
        drop.flatMap { chromeHeights[footerKind($0)] } ?? 0
    }

    // MARK: - Photo

    private func photoLayer(_ drop: SharedDrop, live: Bool) -> some View {
        let image = photo(drop.id)
        let shown = isShown(drop.id)
        return Color.clear
            .overlay {
                // The whole photo, never cropped to the screen's shape, between the header and
                // the reactions. The preview's pixels stay underneath; the photo develops over them.
                ZStack {
                    PixelatedPreview(url: drop.previewURL) { aspects[drop.id] = $0 }
                    if let image {
                        ClickDropDevelopingImage(image: image, isDeveloped: shown, plays: playsDevelop(drop.id))
                            .id(drop.id)
                    }
                }
                .aspectRatio(aspect(drop.id), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottom) {
                    if shown, !captionHidden, let caption = drop.caption {
                        DropCaptionPill { Text(caption) }
                            .padding(.bottom, 14)
                            .transition(.identity)
                    }
                }
                .padding(.top, headerHeight + Self.photoGap)
                .padding(.bottom, footerHeight(drop) + Self.photoGap)
            }
            .overlay { if !shown { developingLabel(drop) } }
            .overlay { if live { tapZones } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(drop.isMine ? "Your drop" : "Drop from \(drop.userName)")
            .accessibilityAction(named: "Next") { advance(1) }
            .accessibilityAction(named: "Previous") { advance(-1) }
            .accessibilityAction(named: playlist == .people ? "Next person" : "Next drop") { jumpChapter(1) }
    }

    private func developingLabel(_ drop: SharedDrop) -> some View {
        Label(store.developing.contains(drop.id) || drop.state() == .ready ? "Developing…" : "Opening…", systemImage: "sparkles")
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCircleBackground()
            // Glass flickers under a fade, so the label comes and goes at once.
            .transition(.identity)
    }

    /// A quick tap on the left third goes back, anywhere else forward; holding pauses; dragging
    /// sideways turns the cube to the next (or previous) person. Measured on screen, not in the
    /// page, since the page itself turns under the finger.
    private var tapZones: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if pressStart == nil { pressStart = .now; holding = true }
                        guard presented, !replyFocused, !cubeSettling else { return }
                        let dx = value.translation.width, dy = value.translation.height
                        if dragAxis == nil, max(abs(dx), abs(dy)) > 10 {
                            dragAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                        }
                        if dragAxis == .horizontal { dragCube(dx) }
                    }
                    .onEnded { value in
                        holding = false
                        let quick = Date().timeIntervalSince(pressStart ?? .now) < 0.25
                        pressStart = nil
                        defer { dragAxis = nil }
                        if dragAxis == .horizontal { return releaseCube(value) }
                        guard quick, abs(value.translation.width) < 16, abs(value.translation.height) < 16 else { return }
                        if replyFocused { focusedReply = nil; return }
                        advance(value.location.x - frame.minX < frame.width / 3 ? -1 : 1)
                    }
            )
    }

    // MARK: - Chrome

    private func header(_ drop: SharedDrop, live: Bool) -> some View {
        VStack(spacing: 10) {
            StoryProgressBar(ids: chapter(chapterKey(drop)).map(\.id), currentID: drop.id, clock: live ? clock : idleClock)
            HStack(spacing: 10) {
                AvatarView(imageURL: drop.avatarURL, seed: drop.userID, initials: Phase3Repository.initials(from: drop.userName), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drop.isMine ? "Your drop" : drop.userName)
                        .font(ClickTypography.supportingEmphasized)
                    if let subtitle = subtitle(drop) {
                        Text(subtitle).font(ClickTypography.metadata).foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    if drop.isMine {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } else {
                        Button("Report", systemImage: "flag") { reporting = true }
                    }
                } label: {
                    ComposerCircleLabel(systemImage: "ellipsis", foreground: .white).contentShape(Circle())
                }
                // Keeps the Liquid Glass circle as the only pressed surface (no rectangular chrome).
                .buttonStyle(.plain)
                .accessibilityLabel("More")
                Button { close() } label: {
                    ComposerCircleLabel(systemImage: "xmark", foreground: .white).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .glassGroup()
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func subtitle(_ drop: SharedDrop) -> String? {
        guard let created = drop.createdAt else { return nil }
        let when = created.formatted(.relative(presentation: .named))
        guard drop.isMine, let audience = drop.audience else { return when }
        return when + (audience == .core ? " · Core connections" : " · All connections")
    }

    /// The reactions sit still from the first frame: no fade while the viewer zooms open or the
    /// photo develops (Liquid Glass flickers under a changing opacity), and your own drop's
    /// reactor row keeps its height while it loads, so nothing at the bottom moves. They only
    /// fade while you type a reply, so they never sit over the keyboard.
    private func footer(_ drop: SharedDrop, live: Bool) -> some View {
        let reactable = isShown(drop.id) && !replyFocused
        return VStack(spacing: 14) {
            ReactionBar(target: .sharedDrop, id: drop.id, isOwner: drop.isMine) { emoji in
                send(emoji, about: drop, reaction: true)
            }
            .id(drop.id)
            .frame(minHeight: drop.isMine ? Self.reactorRowHeight : nil, alignment: .bottomLeading)
            .opacity(replyFocused ? 0 : 1)
            .allowsHitTesting(reactable)
            .accessibilityHidden(!reactable)
            .animation(ClickMotion.subtleFade, value: replyFocused)
            if !drop.isMine, drop.connectionID != nil {
                replyField(drop, live: live)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// The incoming face's field is the same view with no text, so nothing changes as it lands.
    private func replyField(_ drop: SharedDrop, live: Bool) -> some View {
        let trimmed = live ? reply.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let first = drop.userName.split(separator: " ").first.map(String.init) ?? drop.userName
        return HStack(spacing: 10) {
            TextField("Reply to \(first)…", text: live ? $reply : .constant(""), axis: .vertical)
                .lineLimit(1...4)
                .focused($focusedReply, equals: drop.id)
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

    // MARK: - Flow

    private func open(_ id: String) async {
        clock.progress = 0
        guard let drop = store.drop(id) else { return }
        if isShown(id) { unveiled.insert(id) }
        if drop.state() == .ready { await store.develop([drop], fresh: true, env: env) }
        guard let latest = store.drop(id), latest.state() == .developed else { return }
        // Unveil as soon as any copy is here; the full-size one swaps in without a second animation.
        reveal(id)
        if full[id] == nil, let image = await store.fullImage(for: latest, env: env) {
            withAnimation(ClickMotion.subtleFade) { full[id] = image }
        }
        reveal(id)
        prefetchNext(after: id)
    }

    /// The photo unveils: a drop developed just now resolves out of its pixels with a haptic
    /// (a quick fade under Reduce Motion); the label and caption cross-fade.
    private func reveal(_ id: String) {
        guard !unveiled.contains(id), photo(id) != nil else { return }
        if store.freshlyDeveloped.remove(id) != nil {
            ClickHaptics.impact(.medium)
            playing.insert(id)
        }
        withAnimation(ClickMotion.subtleFade) { _ = unveiled.insert(id) }
    }

    /// The next two developed drops (into the next person's, past this person's last) are decoded
    /// before they're shown; near the end of what the archive has loaded, its next page follows.
    private func prefetchNext(after id: String) {
        for next in upcoming(after: id, count: Self.prefetchCount) { loadFull(next.id) }
        // The previous person's too, for turning back.
        if let back = chapterNeighbor(-1) { loadFull(back) }
        if playlist == .archive, let index = store.archiveViewable.firstIndex(where: { $0.id == id }),
           index >= store.archiveViewable.count - 5 {
            Task { await store.loadMoreArchive(env: env) }
        }
    }

    private static let prefetchCount = 2

    private func loadFull(_ id: String) {
        guard full[id] == nil, let drop = store.drop(id), drop.state() == .developed else { return }
        Task {
            if let image = await store.fullImage(for: drop, env: env), keepsFull(id) { full[id] = image }
        }
    }

    /// Full-size photos stay only for the current drop, the one before it and the next few:
    /// each is several megabytes decoded.
    private func keepsFull(_ id: String) -> Bool {
        id == currentID || id == previousID || id == cubeSide?.id || id == chapterNeighbor(-1)
            || upcoming(after: currentID, count: Self.prefetchCount).contains { $0.id == id }
    }

    @State private var previousID: String?

    private func runTimer() async {
        guard !isPaused else { return }
        while !Task.isCancelled && clock.progress < 1 {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            clock.progress = min(1, clock.progress + 0.05 / Self.secondsPerDrop)
        }
        if clock.progress >= 1 { advance(1) }
    }

    /// Through this chapter, then on into the next (or back into the previous) one.
    private func advance(_ step: Int) {
        guard !cubeSettling else { return }
        let ids = sequence.map(\.id)
        guard let index = ids.firstIndex(of: currentID) else { return close() }
        let next = index + step
        if ids.indices.contains(next) { return go(to: ids[next]) }
        jumpChapter(step)
    }

    /// The next person's story (or the previous one's); past the last, the viewer closes, and
    /// before the first, the current drop starts over.
    private func jumpChapter(_ step: Int) {
        guard let drop = current, chapterKeys.contains(chapterKey(drop)) else { return close() }
        guard !cubeSettling else { return }
        if let start = chapterNeighbor(step) { return turnCube(to: start, step: step) }
        if step > 0 { close() } else { clock.progress = 0 }
    }

    /// Where the next (or previous) person's story opens, skipping anyone with nothing to show.
    private func chapterNeighbor(_ step: Int) -> String? {
        let keys = chapterKeys
        guard let drop = current, let at = keys.firstIndex(of: chapterKey(drop)) else { return nil }
        var index = at + step
        while keys.indices.contains(index) {
            if let start = chapterStart(keys[index]) { return start }
            index += step
        }
        return nil
    }

    // MARK: - Cube

    /// Follows the finger. The other face is whoever's on that side; past the first or last
    /// person there's none, and the page only gives a little.
    private func dragCube(_ dx: CGFloat) {
        let step = dx < 0 ? 1 : -1
        if cubeSide?.step != step {
            let id = chapterNeighbor(step)
            cubeSide = CubeSide(step: step, id: id)
            if let id { loadFull(id) }
        }
        cube.x = cubeSide?.id == nil ? dx / 4 : dx
    }

    /// Past a third of the way (or flicked), the turn finishes; otherwise it springs back. Past
    /// the last person, a full swipe closes the viewer instead.
    private func releaseCube(_ value: DragGesture.Value) {
        guard let side = cubeSide else { return }
        let width = max(frame.width, 1)
        let toward = CGFloat(-side.step)
        let far = value.translation.width * toward > width / 3 || value.predictedEndTranslation.width * toward > width * 0.6
        if far, let id = side.id { return turnCube(to: id, step: side.step) }
        if far, side.step > 0 { return close() }
        cubeSettling = true
        withAnimation(Self.cubeAnimation) { cube.x = 0 } completion: {
            cubeSide = nil
            cubeSettling = false
        }
    }

    /// Turns to `id`'s face, then makes it the current page in one still frame: the face is
    /// already exactly where the page sits.
    private func turnCube(to id: String, step: Int) {
        guard presented, !reduceMotion, frame.width > 0 else { return go(to: id) }
        cubeSettling = true
        if cubeSide?.id != id { cubeSide = CubeSide(step: step, id: id) }
        withAnimation(Self.cubeAnimation) { cube.x = CGFloat(-step) * frame.width } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                go(to: id)
                cube.x = 0
                cubeSide = nil
                cubeSettling = false
            }
        }
    }

    private func go(to id: String) {
        clock.progress = 0
        guard id != currentID else { return }
        ClickHaptics.selection()
        // A drop seen again shows developed; it doesn't play its develop twice.
        playing.removeAll()
        previousID = currentID
        currentID = id
        full = full.filter { keepsFull($0.key) }
    }

    private func aspect(_ id: String) -> CGFloat? {
        if let size = photo(id)?.size, size.height > 0 { return size.width / size.height }
        return aspects[id]
    }

    /// Where the current photo sits on screen (global), fitted between the header and footer.
    private var photoRect: CGRect {
        let top = headerHeight + Self.photoGap, bottom = footerHeight(current) + Self.photoGap
        let area = CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: max(frame.height - top - bottom, 1))
        guard let aspect = aspect(currentID) else { return area }
        let size = area.width / area.height > aspect
            ? CGSize(width: area.height * aspect, height: area.height)
            : CGSize(width: area.width, height: area.width / aspect)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// While not presented, the scale and offset that lay the photo over its tile exactly as the
    /// tile fills it, and the tile's rect in the viewer's own (unscaled) space to crop to; nil (a
    /// plain fade) without a visible tile or under Reduce Motion.
    private var collapsed: (scale: CGFloat, offset: CGSize, crop: CGRect)? {
        guard !presented, !reduceMotion, frame.width > 0,
              let tile = sources?.byID[currentID] ?? current.flatMap({ sources?.byID[$0.userID] }),
              tile.intersects(frame) else { return nil }
        let photo = photoRect
        let scale = max(tile.width / photo.width, tile.height / photo.height)
        // scaleEffect scales about the viewer's center; the offset then moves the photo's center
        // onto the tile's.
        let scaledMid = CGPoint(x: frame.midX + (photo.midX - frame.midX) * scale,
                                y: frame.midY + (photo.midY - frame.midY) * scale)
        let size = CGSize(width: tile.width / scale, height: tile.height / scale)
        let crop = CGRect(x: photo.midX - frame.minX - size.width / 2, y: photo.midY - frame.minY - size.height / 2,
                          width: size.width, height: size.height)
        return (scale, CGSize(width: tile.midX - scaledMid.x, height: tile.midY - scaledMid.y), crop)
    }

    /// The viewer's crop: the tile's rect while collapsed onto it, the whole screen, safe areas
    /// included, once presented. A shape whose edges animate directly, so the crop eases between
    /// the two instead of snapping.
    private var crop: ZoomCrop {
        guard let collapsed else {
            return ZoomCrop(top: -insets.top, leading: -insets.leading, bottom: -insets.bottom,
                            trailing: -insets.trailing, radius: 0)
        }
        let c = collapsed.crop
        return ZoomCrop(top: c.minY, leading: c.minX, bottom: frame.height - c.maxY,
                        trailing: frame.width - c.maxX, radius: 16 / collapsed.scale)
    }

    /// Zooms back into the tile (or fades), then takes the viewer's window away.
    private func close() {
        guard presented else { return }
        focusedReply = nil
        holding = true
        withAnimation(Self.zoom) {
            presented = false
            dragY = 0
            cube.x = 0
        }
        // Landing on the tile, the card fades out over it; only then does the viewer go, with
        // nothing left to swap.
        Task {
            try? await Task.sleep(for: .seconds(Self.zoomSettled))
            captionHidden = true
            withAnimation(Self.crossFade) { cardOpacity = 0 } completion: { dismiss() }
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !replyFocused, dragAxis != .horizontal, cubeSide == nil, value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dragY = value.translation.height
                holding = true
            }
            .onEnded { value in
                holding = false
                guard dragY > 0 else { return }
                if value.translation.height > 140 || value.predictedEndTranslation.height > 400 {
                    close()
                } else {
                    withAnimation(ClickMotion.content) { dragY = 0 }
                }
            }
    }

    // MARK: - Replies

    private func sendReply(_ drop: SharedDrop) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        focusedReply = nil
        send(text, about: drop, reaction: false)
    }

    /// Into the 1-1 chat with the poster, through the same optimistic pipeline as any message, so
    /// it's already there when that chat opens.
    private func send(_ text: String, about drop: SharedDrop, reaction: Bool) {
        guard let connectionID = drop.connectionID else { return }
        let route = DirectChatRoute(connectionID: connectionID, peerUserID: drop.userID,
                                    peerDisplayName: drop.userName, peerAvatarURL: drop.avatarURL)
        let model = env.conversationModel(for: route.conversationIdentity)
        Task { await model.sendDropReply(text, to: ChatDropReply(dropID: drop.id, isReaction: reaction)) }
        ClickHaptics.success()
        let first = drop.userName.split(separator: " ").first.map(String.init) ?? drop.userName
        toast = reaction ? "Reaction sent to \(first)" : "Sent to \(first)"
    }

    private func delete() async {
        guard let drop = current else { return }
        do {
            try await env.drops.deleteSharedDrop(id: drop.id)
            store.remove(drop.id, env: env)
        } catch {
            if !error.isCancellation { toast = "Couldn't delete it. \(error.userFacingMessage)" }
        }
    }

    private func report(_ reason: String) async {
        guard let drop = current else { return }
        do {
            try await env.beacons.reportDrop(ClickDropRef(kind: .shared, id: drop.id), reason: reason)
            toast = "Thanks. The Click team will take a look."
        } catch {
            if !error.isCancellation { toast = "Couldn't send the report. \(error.userFacingMessage)" }
        }
    }
}

/// The cube's sideways offset, in points: 0 at rest, a page's width when turned all the way.
@Observable
@MainActor
final class CubeTurn {
    var x: CGFloat = 0
}

/// The cube's other face: which way (1 the next person, -1 the previous) and the drop it opens on.
private struct CubeSide: Equatable {
    let step: Int
    let id: String?
}

/// One face of the cube. Only this reads the offset, so dragging redraws the faces' transforms
/// and nothing inside them.
private struct CubeFace<Content: View>: View {
    let cube: CubeTurn
    /// Where this face sits at rest: 0 in front, 1 to the right, -1 to the left.
    let base: CGFloat
    let width: CGFloat
    let content: Content

    init(cube: CubeTurn, base: CGFloat, width: CGFloat, @ViewBuilder content: () -> Content) {
        self.cube = cube
        self.base = base
        self.width = width
        self.content = content()
    }

    var body: some View {
        content.modifier(CubeEffect(position: width > 0 ? base + cube.x / width : base, width: width))
    }
}

/// A face at `position` (-1 to 1) slides by that many widths and swings on the edge it shares with
/// its neighbour, darkening as it turns away, like Instagram's stories between people.
private struct CubeEffect: ViewModifier, Animatable {
    var position: CGFloat
    let width: CGFloat

    nonisolated var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(position, -1), 1)
        content
            .overlay {
                Color.black.opacity(Double(abs(p)) * 0.5)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .rotation3DEffect(.degrees(Double(p) * 90), axis: (x: 0, y: 1, z: 0),
                              anchor: p < 0 ? .trailing : .leading, perspective: 0.6)
            .offset(x: p * width)
    }
}

/// How far the current drop has played, 0 to 1.
@Observable
@MainActor
final class StoryClock {
    var progress: CGFloat = 0
}

/// One segment per drop: earlier ones full, the current one filling. Only this view reads the
/// clock, so its ticks redraw the bar and nothing else.
private struct StoryProgressBar: View {
    let ids: [String]
    let currentID: String
    let clock: StoryClock

    var body: some View {
        let current = ids.firstIndex(of: currentID) ?? 0
        HStack(spacing: 4) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, _ in
                let fill = index < current ? 1 : (index == current ? clock.progress : 0)
                Capsule()
                    .fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(.white).frame(width: proxy.size.width * fill)
                        }
                    }
                    .frame(height: 2.5)
            }
        }
    }
}

/// Where each drop's tile sits on screen, for the viewer's zoom. A plain reference, not observed:
/// scrolling updates it without re-rendering the strip.
final class DropTileFrames {
    var byID: [String: CGRect] = [:]
}

extension View {
    /// Records this tile's on-screen frame for the drop viewer to zoom out of and back into.
    func dropTileSource(_ id: String, in frames: DropTileFrames) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frames.byID[id] = $0 }
    }

    /// Presents the drop viewer, which runs its own zoom, in a window over this one.
    func dropViewer(_ viewing: Binding<SharedDropsStrip.ViewerStart?>, sources: DropTileFrames) -> some View {
        modifier(DropViewerPresentation(viewing: viewing, sources: sources))
    }
}

extension SharedDropsStrip.ViewerStart {
    static func open(_ id: String, playlist: StoryPlaylist = .people, in viewing: Binding<SharedDropsStrip.ViewerStart?>) {
        viewing.wrappedValue = .init(id: id, playlist: playlist)
    }
}

extension EnvironmentValues {
    /// Takes the drop viewer's window away (the viewer has already zoomed back into its tile).
    @Entry var closeDropViewer: () -> Void = {}
}

/// Shows the viewer in its own window rather than a full-screen cover: covering a screen takes it
/// out of the hierarchy, and putting it back on close re-renders its glass and reloads its photos,
/// a flash right as the viewer lands on its tile. Underneath a window, the screen never changes.
private struct DropViewerPresentation: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var viewing: SharedDropsStrip.ViewerStart?
    let sources: DropTileFrames
    @State private var overlay = DropViewerWindow()

    func body(content: Content) -> some View {
        content
            .onChange(of: viewing?.id) { _, id in
                guard id != nil, let start = viewing else { return overlay.hide() }
                overlay.show(
                    SharedDropStoryViewer(startID: start.id, playlist: start.playlist, sources: sources)
                        .environment(env)
                        .environment(\.closeDropViewer) { viewing = nil }
                )
            }
            .onDisappear { overlay.hide() }
    }
}

@MainActor
private final class DropViewerWindow {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?

    func show(_ view: some View) {
        hide()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .clear
        window.windowLevel = .normal + 1
        previousKey = scene.keyWindow
        // The status bar keeps the screen's style as it fades back in on close.
        window.overrideUserInterfaceStyle = previousKey?.traitCollection.userInterfaceStyle ?? .unspecified
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
    }

    func hide() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        previousKey?.makeKey()
    }
}

/// A rounded rect inset from its bounds by animatable amounts (negative reaches past them).
private struct ZoomCrop: Shape {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(top, leading), AnimatablePair(AnimatablePair(bottom, trailing), radius)) }
        set {
            (top, leading) = (newValue.first.first, newValue.first.second)
            (bottom, trailing) = (newValue.second.first.first, newValue.second.first.second)
            radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cropped = CGRect(x: rect.minX + leading, y: rect.minY + top,
                             width: rect.width - leading - trailing, height: rect.height - top - bottom)
        return Path(roundedRect: cropped, cornerRadius: max(radius, 0), style: .continuous)
    }
}
