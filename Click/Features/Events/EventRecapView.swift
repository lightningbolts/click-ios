import SwiftUI

/// The next-morning recap of an event's Click Drops (spec F1). Every drop opens pixelated and
/// develops when you tap it, whether there's one drop or many; drops you developed before open
/// developed (from disk when they're there). They play in sequence, yours first. Each drop wears
/// its own look, the same on every device; "Natural" shows them all untouched. Bounded: it ends
/// when the drops do.
struct EventRecapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let beaconID: String

    @State private var state = ModuleState<EventDropsState>()
    @State private var photos: [String: RecapPhoto] = [:]
    /// Photos fetched ahead for drops not developed yet: a tap shows them at once.
    @State private var prepared: [String: Loaded] = [:]
    /// Each drop's photo load while it's running (one at a time, shared).
    @State private var inflight: [String: Task<Loaded?, Never>] = [:]
    /// Tapped, photo still on its way: it develops the moment it arrives.
    @State private var revealOnArrival: Set<String> = []
    /// Drops whose photos this device kept (it keeps them only once developed).
    @State private var onDisk: Set<String> = []
    @State private var failed: Set<String> = []
    /// Developed on this screen just now: each resolves out of its pixels once.
    @State private var freshlyDeveloped: Set<String> = []
    @State private var index = 0
    @State private var natural = false
    @State private var isPaused = false
    @State private var confirmDelete: EventDrop?
    @State private var reporting: EventDrop?
    @State private var notice: String?
    @State private var reportedOpen = false

    struct Loaded: Sendable {
        let photo: RecapPhoto
        /// The original's bytes, kept on disk once developed.
        let data: Data
    }

    struct RecapPhoto: Equatable, Sendable {
        let natural: UIImage
        let look: UIImage

        /// Decoded and rendered off the main actor; nil when the bytes aren't an image.
        nonisolated static func make(_ data: Data, look: ClickDropFilter) -> RecapPhoto? {
            guard let natural = ClickDropService.thumbnail(data, maxPixels: maxPixels),
                  let looked = look.renderImage(jpeg: data, maxDimension: maxPixels) else { return nil }
            return RecapPhoto(natural: natural, look: looked)
        }

        private nonisolated static let maxPixels: CGFloat = 1600
    }

    private static let secondsPerDrop: Double = 4
    /// Drops ahead of the current one whose photos are fetched before they show.
    private static let prefetchAhead = 2

    private var cacheKey: String { BeaconExtrasCache.eventDrops(beaconID) }
    private var userID: String? { env.session.currentSession?.userId }

    var body: some View {
        Group {
            if let current = state.value {
                if current.phase != .revealed {
                    developing(current)
                } else if current.drops.isEmpty {
                    ContentUnavailableView("No drops from this one", systemImage: "camera",
                                           description: Text("Nobody added photos to this event."))
                } else {
                    player(current)
                }
            } else if let error = state.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load the recap", systemImage: "exclamationmark.arrow.circlepath")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ClickLoadingView()
            }
        }
        .navigationTitle(state.value.map { $0.access == .absentee ? "What you missed" : $0.eventTitle } ?? "Recap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state.value?.phase == .revealed, state.value?.drops.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $natural) { Label("Natural", systemImage: "camera.filters") }
                        .toggleStyle(.button)
                        .accessibilityHint("Shows every photo without its look.")
                }
            }
        }
        // Opened from the event or Home's card, the drops are usually here already: paint them now.
        .onAppear {
            state.seed(env.beaconExtras.cached(cacheKey))
            noteDisk(state.value?.drops ?? [])
        }
        .task { await load() }
        .confirmation("Delete your drop?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                      keep: "Keep It") {
            Button("Delete", role: .destructive) { if let drop = confirmDelete { Task { await delete(drop) } } }
        }
        .confirmationDialog("Report this photo?", isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } }),
                            titleVisibility: .visible) {
            ForEach(["Inappropriate", "Harassment", "Spam"], id: \.self) { reason in
                Button(reason) { if let drop = reporting { Task { await report(drop, reason: reason) } } }
            }
        } message: {
            Text("Reports go quietly to the Click team. Nobody else sees them.")
        }
        .alert("Recap", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - States

    private func developing(_ current: EventDropsState) -> some View {
        ContentUnavailableView {
            Label("Still developing", systemImage: "hourglass")
        } description: {
            if let reveal = current.revealAt {
                Text("Everyone's drops develop together \(EventDropsState.revealPhrase(reveal)).")
            } else {
                Text("Everyone's drops develop together tomorrow morning.")
            }
        }
        // Left open, it turns into the recap the moment the drops develop.
        .task(id: current.revealAt) {
            guard let reveal = current.revealAt else { return }
            try? await Task.sleep(for: .seconds(max(0, reveal.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func player(_ current: EventDropsState) -> some View {
        let drops = current.drops
        let position = min(index, drops.count - 1)
        let drop = drops[position]
        return VStack(spacing: 12) {
            progress(count: drops.count, position: position)
            ZStack(alignment: .bottomLeading) {
                photo(drop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
                    .overlay {
                        if drop.isMine {
                            RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous)
                                .strokeBorder(ClickColors.accentForeground, lineWidth: 3)
                        }
                    }
                    .overlay { tapZones(drop, position: position, count: drops.count) }
                caption(drop)
                    .padding(12)
            }
            .contextMenu { menu(drop) }
            if position == drops.count - 1 {
                Button("See who was there") { env.router.navigate(to: .eventPeople(beaconID: beaconID)) }
                    .font(ClickTypography.supportingEmphasized)
            }
        }
        .padding(16)
        // The photos just ahead are in hand before they show (refetched when the signed URLs change).
        .task(id: "\(position)-\(drops.map { $0.id + ($0.originalURL?.absoluteString ?? "") }.hashValue)") {
            await prepare(Array(drops[position...].prefix(Self.prefetchAhead + 1)))
        }
        // A developed drop shows for a few seconds, then the next one; an undeveloped one waits for its tap.
        .task(id: "\(position)-\(isPaused)-\(photos[drop.id] != nil)") {
            guard photos[drop.id] != nil else { return }
            // Its develop has started on screen; seen again later this visit, it shows at once.
            freshlyDeveloped.remove(drop.id)
            guard !isPaused, position < drops.count - 1 else { return }
            try? await Task.sleep(for: .seconds(Self.secondsPerDrop))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : ClickMotion.content) { index = position + 1 }
        }
    }

    /// The pixelated preview always sits underneath; the photo develops over it.
    private func photo(_ drop: EventDrop) -> some View {
        ZStack {
            PixelatedPreview(url: drop.previewURL)
            if let photo = photos[drop.id] {
                ClickDropDevelopingImage(image: natural ? photo.natural : photo.look, isDeveloped: true,
                                         plays: !reduceMotion && freshlyDeveloped.contains(drop.id))
                    .transition(.opacity)
            }
        }
        .overlay {
            if photos[drop.id] == nil { status(drop) }
        }
        .id(drop.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(drop.isMine ? "Your drop" : "Drop from \(drop.userName)")
        .accessibilityValue(photos[drop.id] == nil ? "Not developed" : "")
    }

    /// What a tap on an undeveloped drop does, on glass over its pixels.
    private func status(_ drop: EventDrop) -> some View {
        let label: (String, String) = if revealOnArrival.contains(drop.id) || (isDeveloped(drop) && !failed.contains(drop.id)) {
            ("Developing…", "sparkles")
        } else if failed.contains(drop.id) {
            ("Couldn't develop. Tap to retry.", "arrow.clockwise")
        } else {
            ("Tap to develop", "sparkles")
        }
        return Label(label.0, systemImage: label.1)
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCircleBackground()
            // Glass flickers under a fade, so the label changes at once.
            .transition(.identity)
            .allowsHitTesting(false)
    }

    private func caption(_ drop: EventDrop) -> some View {
        HStack(spacing: 8) {
            AvatarView(imageURL: drop.avatarURL, seed: drop.userID, initials: Phase3Repository.initials(from: drop.userName), size: 28)
            Text(drop.isMine ? "Your drop" : drop.userName)
                .font(ClickTypography.supportingEmphasized)
            if !natural, photos[drop.id] != nil { Text("· \(drop.look.name)").font(ClickTypography.supporting).opacity(0.8) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.5), in: Capsule())
    }

    private func progress(count: Int, position: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= position ? ClickColors.textPrimary : ClickColors.separator)
                    .frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Drop \(position + 1) of \(count)")
    }

    /// An undeveloped drop develops on a tap (the left third still goes back, if there's a drop
    /// before it); a developed one moves on: left third back, the rest forward. Holding pauses.
    private func tapZones(_ drop: EventDrop, position: Int, count: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(width: geo.size.width / 3)
                    .onTapGesture { position > 0 ? step(-1, count: count) : tap(drop, count: count) }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { tap(drop, count: count) }
            }
            .onLongPressGesture(minimumDuration: 0.25, pressing: { isPaused = $0 }, perform: {})
        }
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAction(named: "Develop") { tap(drop, count: count) }
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1, count: count)
        }
    }

    private func tap(_ drop: EventDrop, count: Int) {
        if isDeveloped(drop), !failed.contains(drop.id) {
            step(1, count: count)
        } else {
            develop(drop)
        }
    }

    @ViewBuilder
    private func menu(_ drop: EventDrop) -> some View {
        if drop.isMine {
            Button("Delete my drop", systemImage: "trash", role: .destructive) { confirmDelete = drop }
        } else {
            Button("Report", systemImage: "flag") { reporting = drop }
        }
    }

    private func step(_ delta: Int, count: Int) {
        let next = min(max(0, index + delta), count - 1)
        guard next != index else { return }
        ClickHaptics.selection()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : ClickMotion.content) { index = next }
    }

    // MARK: - Loading

    private func load() async {
        state.begin()
        do {
            let loaded = try await env.beaconExtras.loadEventDrops(beaconID, env: env)
            noteDisk(loaded.drops)
            state.succeed(loaded)
            index = min(index, max(0, loaded.drops.count - 1))
            if loaded.phase == .revealed, !loaded.drops.isEmpty, !reportedOpen {
                reportedOpen = true
                await env.productTelemetry.track(.recapOpened)
            }
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    // MARK: - Photos

    /// Developed: the server says so, or this device kept its photo (kept only once developed), so
    /// a tap is remembered across launches even before the server hears of it.
    private func isDeveloped(_ drop: EventDrop) -> Bool {
        drop.developedAt != nil || photos[drop.id] != nil || onDisk.contains(drop.id)
    }

    private func noteDisk(_ drops: [EventDrop]) {
        guard let userID else { return }
        onDisk.formUnion(drops.map(\.id).filter { !onDisk.contains($0) && DropPhotoCache.exists($0, userID: userID) })
    }

    /// Photos for the current drop and the next few, before they're needed: developed ones show as
    /// they arrive; undeveloped ones wait in hand, so their tap shows them at once.
    private func prepare(_ drops: [EventDrop]) async {
        let wanted = drops.filter { photos[$0.id] == nil && prepared[$0.id] == nil && inflight[$0.id] == nil && !revealOnArrival.contains($0.id) }
        guard !wanted.isEmpty else { return }
        // Without a signed original (an older server), a developed drop's comes from developing it
        // again (idempotent). An undeveloped drop is never developed without its tap.
        let unsigned = wanted.filter { $0.originalURL == nil && !onDisk.contains($0.id) && isDeveloped($0) }
        let issued = unsigned.isEmpty ? [:] : await developURLs(unsigned)
        let loads = wanted.compactMap { drop in photo(for: drop, url: drop.originalURL ?? issued[drop.id]).map { (drop, $0) } }
        var missed: [EventDrop] = []
        for (drop, load) in loads {
            let loaded = await load.value
            inflight[drop.id] = nil
            if let loaded { arrive(drop, loaded) } else if isDeveloped(drop) { missed.append(drop) }
        }
        // A developed drop whose signed original lapsed (they last ten minutes): once more, freshly signed.
        guard !missed.isEmpty else { return }
        let fresh = await developURLs(missed)
        for drop in missed {
            let loaded = await photo(for: drop, url: fresh[drop.id])?.value
            inflight[drop.id] = nil
            if let loaded { arrive(drop, loaded) } else { failed.insert(drop.id) }
        }
    }

    /// A photo fetched ahead. A tapped drop is revealed by its tap instead.
    private func arrive(_ drop: EventDrop, _ loaded: Loaded) {
        guard photos[drop.id] == nil, !revealOnArrival.contains(drop.id) else { return }
        if isDeveloped(drop) {
            withAnimation(ClickMotion.subtleFade) { photos[drop.id] = loaded.photo }
            keep(loaded.data, for: drop.id)
        } else {
            prepared[drop.id] = loaded
        }
    }

    /// The tap. The photo is usually in hand and develops at once while the server records the
    /// develop alongside; otherwise it develops the moment it arrives.
    private func develop(_ drop: EventDrop) {
        failed.remove(drop.id)
        if let loaded = prepared[drop.id] {
            reveal(drop, loaded)
            Task { _ = await record(drop) }
            return
        }
        guard !revealOnArrival.contains(drop.id) else { return }
        revealOnArrival.insert(drop.id)
        Task {
            async let recorded = record(drop)
            // Already on its way, or from the recap's signed original.
            var loaded = await photo(for: drop, url: drop.originalURL)?.value
            inflight[drop.id] = nil
            if let loaded {
                reveal(drop, loaded)
                _ = await recorded
                return
            }
            // No original in hand, or it lapsed: the develop's own, freshly signed.
            if let url = await recorded {
                loaded = await photo(for: drop, url: url)?.value
                inflight[drop.id] = nil
            }
            if let loaded { reveal(drop, loaded) } else { revealOnArrival.remove(drop.id); failed.insert(drop.id) }
        }
    }

    /// The photo resolves out of its pixels, once.
    private func reveal(_ drop: EventDrop, _ loaded: Loaded) {
        revealOnArrival.remove(drop.id)
        prepared[drop.id] = nil
        freshlyDeveloped.insert(drop.id)
        photos[drop.id] = loaded.photo
        keep(loaded.data, for: drop.id)
        ClickHaptics.impact(.medium)
    }

    /// The server's half of the tap: records this viewer's develop and returns a freshly signed original.
    private func record(_ drop: EventDrop) async -> URL? {
        guard let result = try? await env.drops.develop([ClickDropRef(kind: .event, id: drop.id)]).first(where: { $0.ref.id == drop.id }),
              result.status == .developed else { return nil }
        markDeveloped(drop.id, at: result.developedAt ?? .now)
        return result.originalURL
    }

    /// Freshly signed originals for drops this viewer already developed.
    private func developURLs(_ drops: [EventDrop]) async -> [String: URL] {
        guard let results = try? await env.drops.develop(drops.map { ClickDropRef(kind: .event, id: $0.id) }) else { return [:] }
        return Dictionary(results.compactMap { r in r.originalURL.map { (r.ref.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// One load per drop at a time (from disk when it's there, else `url`), shared by whoever
    /// needs it; nil when there's nowhere to load it from.
    private func photo(for drop: EventDrop, url: URL?) -> Task<Loaded?, Never>? {
        if let running = inflight[drop.id] { return running }
        guard let userID else { return nil }
        let fromDisk = onDisk.contains(drop.id)
        guard fromDisk || url != nil else { return nil }
        let id = drop.id, look = drop.look
        let task = Task.detached(priority: .userInitiated) {
            await Self.loadPhoto(id: id, look: look, url: url, userID: userID, fromDisk: fromDisk)
        }
        inflight[drop.id] = task
        return task
    }

    private nonisolated static func loadPhoto(id: String, look: ClickDropFilter, url: URL?, userID: String, fromDisk: Bool) async -> Loaded? {
        let data: Data?
        if fromDisk, let saved = DropPhotoCache.data(id, userID: userID) {
            data = saved
        } else if let url {
            data = try? await ClickDropService.loadOriginalData(url)
        } else {
            data = nil
        }
        guard let data, let photo = RecapPhoto.make(data, look: look) else { return nil }
        return Loaded(photo: photo, data: data)
    }

    /// Developed photos stay on this device: every later open (and launch) shows them at once.
    private func keep(_ data: Data, for id: String) {
        guard let userID, !onDisk.contains(id) else { return }
        onDisk.insert(id)
        Task.detached(priority: .utility) { DropPhotoCache.save(data, dropID: id, userID: userID) }
    }

    /// Records a develop on the drops everyone shares, so the event page and the next open agree.
    private func markDeveloped(_ id: String, at date: Date) {
        guard var current = state.value, let i = current.drops.firstIndex(where: { $0.id == id }),
              current.drops[i].developedAt == nil else { return }
        current.drops[i].developedAt = date
        state.succeed(current)
        env.beaconExtras.seed(current, for: cacheKey)
    }

    private func delete(_ drop: EventDrop) async {
        do {
            try await env.beacons.deleteEventDrop(beaconID: beaconID, dropID: drop.id)
            photos[drop.id] = nil
            env.beaconExtras.invalidate(cacheKey)
            await load()
        } catch {
            if !error.isCancellation { notice = "Couldn't delete the drop. \(error.userFacingMessage)" }
        }
    }

    private func report(_ drop: EventDrop, reason: String) async {
        do {
            try await env.beacons.reportDrop(ClickDropRef(kind: .event, id: drop.id), reason: reason)
            notice = "Thanks. The Click team will take a look."
        } catch {
            if !error.isCancellation { notice = "Couldn't send the report. \(error.userFacingMessage)" }
        }
    }
}
