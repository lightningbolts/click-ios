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
    /// Drops being developed or fetched right now (each once at a time).
    @State private var loading: Set<String> = []
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

    struct RecapPhoto: Equatable {
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
    /// Developed drops ahead of the current one that are fetched before they show.
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
        .onAppear { state.seed(env.beaconExtras.cached(cacheKey)) }
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
        // Developed drops just ahead are on hand before they show.
        .task(id: "\(position)-\(drops.map(\.id))") { await fetchDeveloped(Array(drops[position...].prefix(Self.prefetchAhead + 1))) }
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
        let label: (String, String) = if loading.contains(drop.id) || (isDeveloped(drop) && !failed.contains(drop.id)) {
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
            Task { await develop(drop) }
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

    private func isDeveloped(_ drop: EventDrop) -> Bool {
        drop.developedAt != nil || photos[drop.id] != nil
    }

    private func load() async {
        state.begin()
        do {
            let loaded = try await env.beaconExtras.loadEventDrops(beaconID, env: env)
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

    /// The tap: develops one drop for this viewer, then it resolves out of its pixels.
    private func develop(_ drop: EventDrop) async {
        guard !loading.contains(drop.id) else { return }
        failed.remove(drop.id)
        if await fetch([drop], fresh: true) {
            ClickHaptics.impact(.medium)
        }
    }

    /// Drops developed before (here or on another device) that aren't on screen yet: from disk
    /// when they're there, otherwise fetched again (developing again is idempotent).
    private func fetchDeveloped(_ drops: [EventDrop]) async {
        let wanted = drops.filter { $0.developedAt != nil && photos[$0.id] == nil && !loading.contains($0.id) && !failed.contains($0.id) }
        guard !wanted.isEmpty else { return }
        _ = await fetch(wanted, fresh: false)
    }

    /// Gets each drop's photo: the original's bytes from disk, or a develop-issued URL, then its
    /// look rendered off the main actor. Returns whether every drop arrived.
    private func fetch(_ drops: [EventDrop], fresh: Bool) async -> Bool {
        guard let userID else { return false }
        let ids = drops.map(\.id)
        loading.formUnion(ids)
        defer { loading.subtract(ids) }

        // Fresh taps always go to the server: that's what records the develop.
        let onDisk: Set<String> = fresh ? [] : Set(ids.filter { DropPhotoCache.exists($0, userID: userID) })
        var urls: [String: URL] = [:]
        let remote = drops.filter { !onDisk.contains($0.id) }
        if !remote.isEmpty {
            do {
                let results = try await env.drops.develop(remote.map { ClickDropRef(kind: .event, id: $0.id) })
                for result in results where result.status == .developed {
                    if let url = result.originalURL { urls[result.ref.id] = url }
                    if fresh { markDeveloped(result.ref.id, at: result.developedAt ?? .now) }
                }
            } catch {
                if !error.isCancellation { failed.formUnion(remote.map(\.id)) }
                return false
            }
        }

        var arrived = 0
        await withTaskGroup(of: (String, RecapPhoto?).self) { group in
            for drop in drops {
                let id = drop.id, look = drop.look, url = urls[id], cached = onDisk.contains(id)
                guard cached || url != nil else { continue }
                group.addTask {
                    let data: Data?
                    if cached {
                        data = DropPhotoCache.data(id, userID: userID)
                    } else if let url, let downloaded = try? await ClickDropService.loadOriginalData(url) {
                        DropPhotoCache.save(downloaded, dropID: id, userID: userID)
                        data = downloaded
                    } else {
                        data = nil
                    }
                    return (id, data.flatMap { RecapPhoto.make($0, look: look) })
                }
            }
            for await (id, photo) in group {
                guard let photo else { continue }
                arrived += 1
                if fresh { freshlyDeveloped.insert(id) }
                withAnimation(fresh ? nil : ClickMotion.subtleFade) { photos[id] = photo }
            }
        }
        let missing = ids.filter { photos[$0] == nil }
        failed.formUnion(missing)
        return arrived == drops.count
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
