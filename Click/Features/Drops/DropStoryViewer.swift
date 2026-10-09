import SwiftUI

/// One page of a drop story, as the viewer draws it.
struct DropStoryPage: Equatable {
    let id: String
    let userID: String
    let userName: String
    let avatarURL: String?
    let isMine: Bool
    let previewURL: URL?
    /// Under the name: when it was taken, plus whatever the source adds (who it went to, its look).
    let subtitle: String?
    /// Over the photo once it's developed (a Locket-style caption).
    var caption: String? = nil
    /// Width over height, when it's known before any image is here.
    var aspect: CGFloat? = nil
}

/// What a drop story plays and what its pages offer. Home's shared drops and an event's recap each
/// provide one; the viewer owns everything else: the zoom out of a tile and back, chapters with
/// their progress segments, the cube between chapters, the timer, and every tap, hold and swipe.
@MainActor
protocol DropStorySource: AnyObject, Observable {
    /// A decoded photo. The viewer keeps full-size ones only around the current page.
    associatedtype Photo
    associatedtype Footer: View

    /// Chapters in play order (a person's drops, or a single drop), read live.
    var chapterKeys: [String] { get }
    func chapterKey(of id: String) -> String?
    /// A chapter's drops that can be opened, in play order.
    func chapter(_ key: String) -> [String]
    /// Where a chapter opens: its first drop still to develop, say.
    func chapterStart(_ key: String) -> String?
    /// The VoiceOver action that skips to the next chapter ("Next person").
    var nextChapterLabel: String { get }

    func page(_ id: String) -> DropStoryPage?
    /// Developed for this viewer, so its photo may be shown (it may still be on its way).
    func isDeveloped(_ id: String) -> Bool
    /// What sits over the pixels until the photo shows.
    func status(_ id: String) -> (title: String, systemImage: String)
    /// A page opening: Home develops a ready drop on sight. Returns once that's done.
    func open(_ id: String) async
    /// These pages are next: anything slow about them (an undeveloped photo, a next page) starts now.
    func prepare(_ ids: [String])
    /// A tap on this page develops it instead of moving on (an event recap's drops wait for theirs).
    func tapDevelops(_ id: String) -> Bool
    func develop(_ id: String) async

    /// A copy already decoded (a tile's or the grid's), shown until the full-size one arrives.
    func cachedPhoto(_ id: String) -> Photo?
    func fullPhoto(_ id: String) async -> Photo?
    func image(_ photo: Photo) -> UIImage
    /// Kept on this device: the viewer waits the moment it takes to decode instead of unveiling it.
    func isSaved(_ id: String) -> Bool
    /// Developed just now, so it plays its develop as it unveils (once: `consumeFresh`).
    func isFresh(_ id: String) -> Bool
    func consumeFresh(_ id: String) -> Bool

    var deleteMessage: String { get }
    func delete(_ id: String) async throws
    func report(_ id: String, reason: String) async throws

    /// Below the photo, the same height on every page (it may grow up over the photo, outside its
    /// layout); only the `live` page takes input, and `shown` once its photo is unveiled.
    @ViewBuilder func footer(_ id: String, live: Bool, shown: Bool, interaction: DropStoryInteraction) -> Footer
}

/// What a page's footer shares with the viewer while a story plays.
@Observable
@MainActor
final class DropStoryInteraction {
    /// Typing in the footer: the story holds, and a tap dismisses the keyboard instead of moving on.
    var composing = false
    /// A sheet is up over the drop.
    var presenting = false
    var toast: String?
    /// Zooms back into the tile, then runs `then` once the viewer is gone (set by the viewer).
    @ObservationIgnored var close: (_ then: (() -> Void)?) -> Void = { _ in }
}

/// Click Drops, Instagram-story style: zooms out of the tapped tile, then one drop after another
/// with progress segments for the current chapter; past its last drop it carries on to the next.
/// Tap the sides to move, swipe sideways to turn (a cube, like Instagram) to the next or previous
/// chapter, hold to pause, swipe down to close. A drop developed on this screen unveils from its
/// pixels.
struct DropStoryViewer<Source: DropStorySource>: View {
    @Environment(\.closeDropViewer) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var source: Source
    @State private var interaction = DropStoryInteraction()
    @State private var currentID: String
    /// Ticks in its own view (the progress bar), so the viewer doesn't re-render while a drop plays.
    @State private var clock = StoryClock()
    @State private var holding = false
    @State private var pressStart: Date?
    /// Full-size photos for this viewing (tiles keep small copies).
    @State private var full: [String: Source.Photo] = [:]
    @State private var unveiled: Set<String> = []
    /// Developed on this screen just now: they play the develop when they unveil.
    @State private var playing: Set<String> = []
    @State private var dragY: CGFloat = 0
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
    /// The header's and the footer's height: the photo sits in the space between them, and the
    /// next chapter's page lays out the same before it's measured.
    @State private var chromeHeights: [String: CGFloat] = [:]
    /// The sideways turn between chapters, Instagram's cube: the drag (or turn) offset, observed
    /// only by the two faces so a drag doesn't re-render the viewer.
    @State private var cube = CubeTurn()
    /// The chapter's page on the cube's other face while dragging or turning: which way, and the
    /// drop it opens on (nil past the first or last chapter).
    @State private var cubeSide: CubeSide?
    /// Finishing a turn or springing back: gestures and the timer wait for it.
    @State private var cubeSettling = false
    @State private var dragAxis: Axis?
    /// The progress bar on the incoming face: its current segment sits empty.
    @State private var idleClock = StoryClock()
    @State private var previousID: String?
    /// Runs once the viewer is gone (a footer closing it to go somewhere else).
    @State private var afterClose: (() -> Void)?
    private let sources: DropTileFrames?

    private static var secondsPerDrop: Double { 6 }
    /// The gap between the photo and the header above it or the footer below.
    private static var photoGap: CGFloat { 8 }
    /// Quicker than the system zoom, so a drop feels like it pops open. A curve rather than a
    /// spring, so it lands on time: by `zoomSettled` it's within a few points of the tile, and
    /// the card can fade over it without ghosting.
    private static var zoom: Animation { .timingCurve(0.25, 0.8, 0.25, 1, duration: 0.2) }
    private static var zoomSettled: Double { 0.14 }
    /// The cube finishing a turn (or springing back): quick, no overshoot.
    private static var cubeAnimation: Animation { .snappy(duration: 0.32) }
    /// The card and its tile trading places at either end of the zoom: quick on the way out of
    /// the tile, before the card has grown enough to show the screen through it.
    private static var crossFadeIn: Animation { .easeOut(duration: 0.06) }
    private static var crossFade: Animation { .easeInOut(duration: 0.1) }
    private static var prefetchCount: Int { 2 }

    /// Present with animations disabled: the viewer runs its own zoom out of `sources`' tile
    /// (keyed by drop, else by person), or a fade without one or under Reduce Motion.
    init(source: Source, startID: String, sources: DropTileFrames? = nil) {
        _source = State(initialValue: source)
        _currentID = State(initialValue: startID)
        self.sources = sources
    }

    // MARK: - Chapters

    private var current: DropStoryPage? { source.page(currentID) }

    /// The current chapter: what the progress bar shows and taps move through.
    private var sequence: [String] { chapter(of: currentID) }

    private func chapter(of id: String) -> [String] {
        source.chapterKey(of: id).map(source.chapter) ?? []
    }

    /// The drops that play after `id`, across chapters, for prefetching.
    private func upcoming(after id: String, count: Int) -> [String] {
        guard let key = source.chapterKey(of: id) else { return [] }
        var out = Array(source.chapter(key).drop { $0 != id }.dropFirst().prefix(count))
        let keys = source.chapterKeys
        var index = (keys.firstIndex(of: key) ?? keys.count) + 1
        while out.count < count, keys.indices.contains(index) {
            let start = source.chapterStart(keys[index])
            out += source.chapter(keys[index]).drop { $0 != start }.prefix(count - out.count)
            index += 1
        }
        return out
    }

    /// Any copy on hand: the full-size one, else the tile's or the grid's.
    private func photo(_ id: String) -> UIImage? {
        (full[id] ?? source.cachedPhoto(id)).map(source.image)
    }

    /// A photo already on hand (and not just developed) shows from the first frame, so nothing
    /// swaps in while the viewer is still zooming open.
    private func isShown(_ id: String) -> Bool {
        unveiled.contains(id) || (photo(id) != nil && !source.isFresh(id))
    }

    private func playsDevelop(_ id: String) -> Bool {
        !reduceMotion && (playing.contains(id) || source.isFresh(id))
    }

    private var isPaused: Bool {
        holding || interaction.composing || interaction.presenting || confirmDelete || reporting
            || cubeSide != nil || !isShown(currentID)
    }

    var body: some View {
        ZStack {
            // The screen dims to black behind the zooming card, so the card's growing edge never
            // wipes across the tab bar. Plain black, no glass, so it can fade; it lifts as you drag.
            Color.black.ignoresSafeArea()
                .opacity(presented ? Double(1 - min(dragY, 240) / 240) : 0)
            card
        }
        // Our own swipe-down (which also pauses) closes, zooming back into the tile.
        .simultaneousGesture(dismissDrag)
        .task {
            interaction.close = { then in
                afterClose = then
                close()
            }
            // Zoom once the viewer has been laid out over its tile, so it never fades in.
            for _ in 0..<20 where frame == .zero {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await Task.yield()
            // A developed photo that's on disk but not in memory decodes in a few frames: wait for
            // it, so the viewer opens on the photo instead of unveiling it out of the pixels.
            let id = currentID
            if !isShown(id), source.isDeveloped(id), source.isSaved(id), let photo = await source.fullPhoto(id) {
                full[id] = photo
            }
            captionHidden = false
            withAnimation(Self.zoom) { presented = true }
            withAnimation(Self.crossFadeIn) { cardOpacity = 1 }
        }
        .environment(\.colorScheme, .dark)
        // Follows the zoom, so the status bar fades back as the card shrinks, not after.
        .statusBarHidden(presented)
        .clickToast($interaction.toast, edge: .top)
        .task(id: currentID) { await open(currentID) }
        .task(id: "\(currentID)|\(isPaused)") { await runTimer() }
        .onChange(of: current == nil) { _, gone in if gone { close() } }
        .confirmation("Delete this drop?", isPresented: $confirmDelete, keep: "Keep It", message: source.deleteMessage) {
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
            ForEach(faces, id: \.page.id) { face in
                CubeFace(cube: cube, base: face.base, width: frame.width) {
                    page(face.page, live: face.page.id == currentID)
                }
            }
        }
        .offset(y: dragY)
        .scaleEffect(1 - min(dragY, 400) / 2400)
        // Zooming, the viewer stays opaque and is cropped to the tile's shape instead of fading:
        // Liquid Glass (the header, caption and footer) flickers under a changing opacity.
        .clipShape(crop)
        .scaleEffect(collapsed?.scale ?? 1)
        .offset(collapsed?.offset ?? .zero)
        // Flattened first, so the card fades onto the tile as one picture: faded layer by layer,
        // the pixelated preview under the photo shows through and the tile flashes dark and blocky.
        .compositingGroup()
        .opacity(presented || collapsed != nil ? cardOpacity : 0)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
        .onGeometryChange(for: EdgeInsets.self, of: { $0.safeAreaInsets }) { insets = $0 }
    }

    /// The current page, and the next (or previous) chapter's on the cube's other face.
    private var faces: [(page: DropStoryPage, base: CGFloat)] {
        guard let current else { return [] }
        var out: [(page: DropStoryPage, base: CGFloat)] = []
        for (step, id) in sideFaces {
            if id != currentID, let other = source.page(id) { out.append((other, CGFloat(step))) }
        }
        return out + [(current, 0)]
    }

    /// The faces beside the current one. Mid-turn, the one being turned to; otherwise, at either
    /// end of a chapter, whatever a tap or the timer would turn to, mounted edge-on out of sight so
    /// the turn animates a face that already exists (one inserted mid-animation would just appear
    /// at its end).
    private var sideFaces: [(step: Int, id: String)] {
        if let side = cubeSide { return side.id.map { [(side.step, $0)] } ?? [] }
        let ids = sequence
        var out: [(step: Int, id: String)] = []
        if ids.first == currentID, let id = chapterNeighbor(-1) { out.append((-1, id)) }
        if ids.last == currentID, let id = chapterNeighbor(1) { out.append((1, id)) }
        return out
    }

    /// One drop's page: the photo between its header and footer. Only the current page takes
    /// touches and measures; the incoming one is a still copy.
    private func page(_ page: DropStoryPage, live: Bool) -> some View {
        ZStack {
            photoLayer(page, live: live)
                .ignoresSafeArea(.keyboard)
            VStack(spacing: 0) {
                header(page, live: live)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured("header", $0, live: live) }
                Spacer(minLength: 0)
                source.footer(page.id, live: live, shown: isShown(page.id), interaction: interaction)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured("footer", $0, live: live) }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .allowsHitTesting(live)
        .accessibilityHidden(!live)
    }

    private func measured(_ key: String, _ height: CGFloat, live: Bool) {
        guard live || chromeHeights[key] == nil, chromeHeights[key] != height else { return }
        chromeHeights[key] = height
    }

    private var headerHeight: CGFloat { chromeHeights["header"] ?? 0 }
    private var footerHeight: CGFloat { chromeHeights["footer"] ?? 0 }

    // MARK: - Photo

    private func photoLayer(_ page: DropStoryPage, live: Bool) -> some View {
        let image = photo(page.id)
        let shown = isShown(page.id)
        return Color.clear
            .overlay {
                // The whole photo, never cropped to the screen's shape, between the header and
                // the footer. The preview's pixels stay underneath; the photo develops over them.
                ZStack {
                    PixelatedPreview(url: page.previewURL) { aspects[page.id] = $0 }
                    if let image {
                        ClickDropDevelopingImage(image: image, isDeveloped: shown, plays: playsDevelop(page.id))
                            .id(page.id)
                    }
                }
                .aspectRatio(aspect(page.id), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottom) {
                    if shown, !captionHidden, let caption = page.caption {
                        DropCaptionPill { Text(caption) }
                            .padding(.bottom, 14)
                            .transition(.identity)
                    }
                }
                .padding(.top, headerHeight + Self.photoGap)
                .padding(.bottom, footerHeight + Self.photoGap)
            }
            .overlay { if !shown { statusLabel(page.id) } }
            .overlay { if live { tapZones } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(page.isMine ? "Your drop" : "Drop from \(page.userName)")
            .accessibilityValue(shown ? "" : source.status(page.id).title)
            .accessibilityActions {
                if live, source.tapDevelops(page.id) {
                    Button("Develop") { develop(page.id) }
                }
                Button("Next") { advance(1) }
                Button("Previous") { advance(-1) }
                Button(source.nextChapterLabel) { jumpChapter(1) }
            }
    }

    private func statusLabel(_ id: String) -> some View {
        let status = source.status(id)
        return Label(status.title, systemImage: status.systemImage)
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCircleBackground()
            // Glass flickers under a fade, so the label comes and goes at once.
            .transition(.identity)
            .allowsHitTesting(false)
    }

    /// A quick tap on the left third goes back, anywhere else forward (or develops a drop that
    /// waits for its tap); holding pauses; dragging sideways turns the cube to the next (or
    /// previous) chapter. Measured on screen, not in the page, since the page itself turns under
    /// the finger.
    private var tapZones: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if pressStart == nil { pressStart = .now; holding = true }
                        guard presented, !interaction.composing, !cubeSettling else { return }
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
                        if interaction.composing { interaction.composing = false; return }
                        let back = value.location.x - frame.minX < frame.width / 3
                        if !back, source.tapDevelops(currentID) { return develop(currentID) }
                        advance(back ? -1 : 1)
                    }
            )
    }

    // MARK: - Chrome

    private func header(_ page: DropStoryPage, live: Bool) -> some View {
        VStack(spacing: 10) {
            StoryProgressBar(ids: chapter(of: page.id), currentID: page.id, clock: live ? clock : idleClock)
            HStack(spacing: 10) {
                AvatarView(imageURL: page.avatarURL, seed: page.userID, initials: Phase3Repository.initials(from: page.userName), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.isMine ? "Your drop" : page.userName)
                        .font(ClickTypography.supportingEmphasized)
                    if let subtitle = page.subtitle {
                        Text(subtitle).font(ClickTypography.metadata).foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    if page.isMine {
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

    // MARK: - Flow

    private func open(_ id: String) async {
        clock.progress = 0
        guard source.page(id) != nil else { return }
        if isShown(id) { unveiled.insert(id) }
        source.prepare([id] + upcoming(after: id, count: Self.prefetchCount))
        await source.open(id)
        guard source.isDeveloped(id) else { return }
        // Unveil as soon as any copy is here; the full-size one swaps in without a second animation.
        reveal(id)
        if full[id] == nil, let photo = await source.fullPhoto(id) {
            withAnimation(ClickMotion.subtleFade) { full[id] = photo }
        }
        reveal(id)
        prefetchNext(after: id)
    }

    /// The tap that develops a drop; it unveils here the moment its photo is in hand.
    private func develop(_ id: String) {
        Task {
            await source.develop(id)
            if id == currentID { await open(id) }
        }
    }

    /// The photo unveils: a drop developed just now resolves out of its pixels with a haptic
    /// (a quick fade under Reduce Motion); the label and caption cross-fade.
    private func reveal(_ id: String) {
        guard !unveiled.contains(id), photo(id) != nil else { return }
        if source.consumeFresh(id) {
            ClickHaptics.impact(.medium)
            playing.insert(id)
        }
        withAnimation(ClickMotion.subtleFade) { _ = unveiled.insert(id) }
    }

    /// The next two developed drops (into the next chapter, past this one's last) are decoded
    /// before they're shown, and the previous chapter's for turning back.
    private func prefetchNext(after id: String) {
        for next in upcoming(after: id, count: Self.prefetchCount) { loadFull(next) }
        if let back = chapterNeighbor(-1) { loadFull(back) }
    }

    private func loadFull(_ id: String) {
        guard full[id] == nil, source.isDeveloped(id) else { return }
        Task {
            if let photo = await source.fullPhoto(id), keepsFull(id) { full[id] = photo }
        }
    }

    /// Full-size photos stay only for the current drop, the one before it and the next few:
    /// each is several megabytes decoded.
    private func keepsFull(_ id: String) -> Bool {
        id == currentID || id == previousID || id == cubeSide?.id || id == chapterNeighbor(-1)
            || upcoming(after: currentID, count: Self.prefetchCount).contains(id)
    }

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
        let ids = sequence
        guard let index = ids.firstIndex(of: currentID) else { return close() }
        let next = index + step
        if ids.indices.contains(next) { return go(to: ids[next]) }
        jumpChapter(step)
    }

    /// The next chapter (or the previous one); past the last, the viewer closes, and before the
    /// first, the current drop starts over.
    private func jumpChapter(_ step: Int) {
        guard let key = source.chapterKey(of: currentID), source.chapterKeys.contains(key) else { return close() }
        guard !cubeSettling else { return }
        if let start = chapterNeighbor(step) { return turnCube(to: start, step: step) }
        if step > 0 { close() } else { clock.progress = 0 }
    }

    /// Where the next (or previous) chapter opens, skipping any with nothing to show.
    private func chapterNeighbor(_ step: Int) -> String? {
        let keys = source.chapterKeys
        guard let key = source.chapterKey(of: currentID), let at = keys.firstIndex(of: key) else { return nil }
        var index = at + step
        while keys.indices.contains(index) {
            if let start = source.chapterStart(keys[index]) { return start }
            index += step
        }
        return nil
    }

    // MARK: - Cube

    /// Follows the finger. The other face is whichever chapter is on that side; past the first or
    /// last there's none, and the page only gives a little.
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
    /// the last chapter, a full swipe closes the viewer instead.
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
        return aspects[id] ?? source.page(id)?.aspect
    }

    /// Where the current photo sits on screen (global), fitted between the header and footer.
    private var photoRect: CGRect {
        let top = headerHeight + Self.photoGap, bottom = footerHeight + Self.photoGap
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
        interaction.composing = false
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
            withAnimation(Self.crossFade) { cardOpacity = 0 } completion: {
                dismiss()
                afterClose?()
            }
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !interaction.composing, dragAxis != .horizontal, cubeSide == nil, value.translation.height > 0,
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

    // MARK: - Delete and report

    private func delete() async {
        let id = currentID
        do {
            try await source.delete(id)
        } catch {
            if !error.isCancellation { interaction.toast = "Couldn't delete it. \(error.userFacingMessage)" }
        }
    }

    private func report(_ reason: String) async {
        do {
            try await source.report(currentID, reason: reason)
            interaction.toast = "Thanks. The Click team will take a look."
        } catch {
            if !error.isCancellation { interaction.toast = "Couldn't send the report. \(error.userFacingMessage)" }
        }
    }
}

/// The cube's sideways offset, in points: 0 at rest, a page's width when turned all the way.
@Observable
@MainActor
final class CubeTurn {
    var x: CGFloat = 0
}

/// The cube's other face: which way (1 the next chapter, -1 the previous) and the drop it opens on.
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
        .accessibilityHidden(true)
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

    /// Presents a drop story, which runs its own zoom, in a window over this one while `item` is set.
    func dropStory<Item: Identifiable, Viewer: View>(
        _ item: Binding<Item?>,
        @ViewBuilder viewer: @escaping (Item) -> Viewer
    ) -> some View {
        modifier(DropViewerPresentation(item: item, viewer: viewer))
    }
}

extension EnvironmentValues {
    /// Takes the drop viewer's window away (the viewer has already zoomed back into its tile).
    @Entry var closeDropViewer: () -> Void = {}
}

/// Shows the viewer in its own window rather than a full-screen cover: covering a screen takes it
/// out of the hierarchy, and putting it back on close re-renders its glass and reloads its photos,
/// a flash right as the viewer lands on its tile. Underneath a window, the screen never changes.
private struct DropViewerPresentation<Item: Identifiable, Viewer: View>: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var item: Item?
    let viewer: (Item) -> Viewer
    @State private var overlay = DropViewerWindow()

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id) { _, id in
                guard id != nil, let item else { return overlay.hide() }
                overlay.show(
                    viewer(item)
                        .environment(env)
                        .environment(\.closeDropViewer) { self.item = nil }
                )
            }
            // Navigating away takes the viewer with it, and the same tile opens it again.
            .onDisappear { overlay.hide(); item = nil }
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
