import SwiftUI

/// Shared Click Drops, Instagram-story style: zooms out of the tapped tile, then one drop after
/// another with progress segments; tap the sides to move, hold to pause, swipe down to close. A ready drop develops right
/// here, unveiling from its pixels. Replies and reactions go to your chat with the poster and
/// carry the drop with them; your own drops show who reacted instead.
struct SharedDropStoryViewer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentID: String
    /// Ticks in its own view (the progress bar), so the viewer doesn't re-render while a drop plays.
    @State private var clock = StoryClock()
    @State private var holding = false
    @State private var pressStart: Date?
    @State private var reply = ""
    @FocusState private var replyFocused: Bool
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
    @State private var frame: CGRect = .zero
    @State private var insets = EdgeInsets()
    /// Each drop's shape (width over height), from its photo or, before that, its preview.
    @State private var aspects: [String: CGFloat] = [:]
    /// The header's and footer's heights: the photo sits in the space between them.
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    private let sources: DropTileFrames?

    private static let secondsPerDrop: Double = 6
    /// Your own drop's reactor row (a face, its emoji and a name), held while reactions load.
    private static let reactorRowHeight: CGFloat = 68
    /// The gap between the photo and the header above it or the reactions below.
    private static let photoGap: CGFloat = 8
    /// Quicker than the system zoom, so a drop feels like it pops open.
    private static let zoom = Animation.snappy(duration: 0.26)

    /// Present with animations disabled: the viewer runs its own zoom out of `sources`' tile
    /// (or a fade without one, or under Reduce Motion).
    init(startID: String, sources: DropTileFrames? = nil) {
        _currentID = State(initialValue: startID)
        self.sources = sources
    }

    private var store: SharedDropsStore { env.sharedDropsStore }
    private var sequence: [SharedDrop] { store.viewable }
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
        holding || replyFocused || confirmDelete || reporting || !isShown(currentID)
    }

    var body: some View {
        ZStack {
            // Home dims to black behind the zooming card, so the card's growing edge never wipes
            // across the tab bar. Plain black, no glass, so it can fade; it lifts as you drag.
            Color.black.ignoresSafeArea()
                .opacity(presented ? 1 - min(dragY, 240) / 240 : 0)
            card
        }
        .presentationBackground(.clear)
        .simultaneousGesture(dismissDrag)
        // Our own swipe-down (which also pauses) closes, zooming back into the tile.
        .interactiveDismissDisabled()
        .task {
            // Zoom once the viewer has been laid out over its tile, so it never fades in.
            for _ in 0..<20 where frame == .zero {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await Task.yield()
            withAnimation(Self.zoom) { presented = true }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .clickToast($toast, edge: .top)
        .task(id: currentID) { await open(currentID) }
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
            if let drop = current {
                photoLayer(drop)
                    .ignoresSafeArea(.keyboard)
                VStack(spacing: 0) {
                    header(drop)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
                    Spacer(minLength: 0)
                    footer(drop)
                        // Held while typing, so a growing reply never shrinks the photo.
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if !replyFocused { footerHeight = $0 } }
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
        .opacity(presented || collapsed != nil ? 1 : 0)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
        .onGeometryChange(for: EdgeInsets.self, of: { $0.safeAreaInsets }) { insets = $0 }
    }

    // MARK: - Photo

    private func photoLayer(_ drop: SharedDrop) -> some View {
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
                    if shown, let caption = drop.caption {
                        DropCaptionPill { Text(caption) }
                            .padding(.bottom, 14)
                            .transition(.identity)
                    }
                }
                .padding(.top, headerHeight + Self.photoGap)
                .padding(.bottom, footerHeight + Self.photoGap)
            }
            .overlay { if !shown { developingLabel(drop) } }
            .overlay { tapZones }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(drop.isMine ? "Your drop" : "Drop from \(drop.userName)")
            .accessibilityAction(named: "Next") { advance(1) }
            .accessibilityAction(named: "Previous") { advance(-1) }
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

    /// A quick tap on the left third goes back, anywhere else forward; holding pauses.
    private var tapZones: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if pressStart == nil { pressStart = .now; holding = true }
                        }
                        .onEnded { value in
                            holding = false
                            let quick = Date().timeIntervalSince(pressStart ?? .now) < 0.25
                            pressStart = nil
                            guard quick, abs(value.translation.width) < 16, abs(value.translation.height) < 16 else { return }
                            if replyFocused { replyFocused = false; return }
                            advance(value.location.x < proxy.size.width / 3 ? -1 : 1)
                        }
                )
        }
    }

    // MARK: - Chrome

    private func header(_ drop: SharedDrop) -> some View {
        VStack(spacing: 10) {
            StoryProgressBar(ids: sequence.map(\.id), currentID: currentID, clock: clock)
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
    private func footer(_ drop: SharedDrop) -> some View {
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
                replyField(drop)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func replyField(_ drop: SharedDrop) -> some View {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = drop.userName.split(separator: " ").first.map(String.init) ?? drop.userName
        return HStack(spacing: 10) {
            TextField("Reply to \(first)…", text: $reply, axis: .vertical)
                .lineLimit(1...4)
                .focused($replyFocused)
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

    /// The next developed drop's photo is decoded before it's shown.
    private func prefetchNext(after id: String) {
        guard let index = sequence.firstIndex(where: { $0.id == id }), index + 1 < sequence.count else { return }
        let next = sequence[index + 1]
        guard next.state() == .developed, full[next.id] == nil else { return }
        Task {
            if let image = await store.fullImage(for: next, env: env) { full[next.id] = image }
        }
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

    private func advance(_ step: Int) {
        guard let index = sequence.firstIndex(where: { $0.id == currentID }) else { return close() }
        let next = index + step
        if next >= sequence.count { return close() }
        guard next >= 0 else { clock.progress = 0; return }
        ClickHaptics.selection()
        // A drop seen again shows developed; it doesn't play its develop twice.
        playing.removeAll()
        currentID = sequence[next].id
    }

    private func aspect(_ id: String) -> CGFloat? {
        if let size = photo(id)?.size, size.height > 0 { return size.width / size.height }
        return aspects[id]
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
              let tile = sources?.byID[currentID], tile.intersects(frame) else { return nil }
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

    /// Zooms back into the tile (or fades), then dismisses without the system animation.
    private func close() {
        guard presented else { return }
        replyFocused = false
        holding = true
        withAnimation(Self.zoom) {
            presented = false
            dragY = 0
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !replyFocused, value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                dragY = value.translation.height
                holding = true
            }
            .onEnded { value in
                holding = false
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
        replyFocused = false
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

    /// Presents the drop viewer without the system's animation; it runs its own quicker zoom.
    func dropViewer(_ viewing: Binding<SharedDropsStrip.ViewerStart?>, sources: DropTileFrames) -> some View {
        fullScreenCover(item: viewing) { start in SharedDropStoryViewer(startID: start.id, sources: sources) }
    }
}

extension SharedDropsStrip.ViewerStart {
    /// Opens a drop with the presentation itself unanimated (the viewer animates its own way in).
    static func open(_ id: String, in viewing: Binding<SharedDropsStrip.ViewerStart?>) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { viewing.wrappedValue = .init(id: id) }
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
