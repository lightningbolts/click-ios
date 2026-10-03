import SwiftUI

/// The next-morning recap of an event's Click Drops (spec F1). Opening it develops every photo
/// (no per-photo taps); they play in sequence, yours first. Each drop wears its own look, the same
/// on every device; "Natural" shows them all untouched. Bounded: it ends when the drops do.
struct EventRecapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let beaconID: String

    @State private var state = ModuleState<EventDropsState>()
    @State private var photos: [String: RecapPhoto] = [:]
    @State private var failed: Set<String> = []
    @State private var index = 0
    @State private var natural = false
    @State private var isPaused = false
    /// Drops that already played their develop animation this visit.
    @State private var developedOnScreen: Set<String> = []
    @State private var confirmDelete: EventDrop?
    @State private var reporting: EventDrop?
    @State private var notice: String?
    @State private var reportedOpen = false

    struct RecapPhoto: Equatable {
        let natural: UIImage
        let look: UIImage
    }

    private static let secondsPerDrop: Double = 4

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
                Text("Everyone's drops develop together \(reveal.formatted(.relative(presentation: .named))), at \(reveal.formatted(date: .omitted, time: .shortened)).")
            } else {
                Text("Everyone's drops develop together tomorrow morning.")
            }
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
                    .overlay { tapZones(count: drops.count) }
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
        .task(id: "\(position)-\(isPaused)-\(photos[drop.id] != nil)") {
            await present(drop)
            guard !isPaused, photos[drop.id] != nil, position < drops.count - 1 else { return }
            try? await Task.sleep(for: .seconds(Self.secondsPerDrop))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : ClickMotion.content) { index = position + 1 }
        }
    }

    @ViewBuilder
    private func photo(_ drop: EventDrop) -> some View {
        if let photo = photos[drop.id] {
            // Each drop resolves out of its pixels the first time it shows this visit.
            ZStack {
                PixelatedPreview(url: drop.previewURL)
                ClickDropDevelopingImage(image: natural ? photo.natural : photo.look, isDeveloped: true,
                                         plays: !reduceMotion && !developedOnScreen.contains(drop.id))
            }
            .id(drop.id)
                .transition(.opacity)
                .accessibilityLabel(drop.isMine ? "Your drop" : "Drop from \(drop.userName)")
        } else if failed.contains(drop.id) {
            Button {
                failed.remove(drop.id)
                Task { await developAll() }
            } label: {
                Label("Couldn't develop this one. Tap to retry.", systemImage: "arrow.clockwise")
                    .font(ClickTypography.supporting)
            }
        } else {
            ZStack {
                PixelatedPreview(url: drop.previewURL).shimmering()
            }
        }
    }

    private func caption(_ drop: EventDrop) -> some View {
        HStack(spacing: 8) {
            AvatarView(imageURL: drop.avatarURL, seed: drop.userID, initials: Phase3Repository.initials(from: drop.userName), size: 28)
            Text(drop.isMine ? "Your drop" : drop.userName)
                .font(ClickTypography.supportingEmphasized)
            if !natural { Text("· \(drop.look.name)").font(ClickTypography.supporting).opacity(0.8) }
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

    /// Left third goes back, the rest goes forward; holding pauses.
    private func tapZones(count: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(width: geo.size.width / 3)
                    .onTapGesture { step(-1, count: count) }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { step(1, count: count) }
            }
            .onLongPressGesture(minimumDuration: 0.25, pressing: { isPaused = $0 }, perform: {})
        }
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1, count: count)
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
            let loaded = try await env.beacons.eventDrops(beaconID: beaconID)
            state.succeed(loaded)
            index = min(index, max(0, loaded.drops.count - 1))
            if loaded.phase == .revealed {
                if !loaded.drops.isEmpty, !reportedOpen {
                    reportedOpen = true
                    await env.productTelemetry.track(.recapOpened)
                }
                await developAll()
            }
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    /// Opening the recap is the tap: every drop develops, then downloads in order.
    private func developAll() async {
        guard let drops = state.value?.drops, !drops.isEmpty else { return }
        let pending = drops.filter { photos[$0.id] == nil }
        guard !pending.isEmpty else { return }
        let results: [ClickDropDevelopResult]
        do {
            results = try await env.drops.develop(pending.map { ClickDropRef(kind: .event, id: $0.id) })
        } catch {
            if !error.isCancellation { failed.formUnion(pending.map(\.id)) }
            return
        }
        let urls = Dictionary(results.compactMap { r in r.originalURL.map { (r.ref.id, $0) } }, uniquingKeysWith: { a, _ in a })
        failed.formUnion(pending.map(\.id).filter { urls[$0] == nil })
        await withTaskGroup(of: (String, RecapPhoto?).self) { group in
            for drop in pending {
                guard let url = urls[drop.id] else { continue }
                let look = drop.look
                group.addTask {
                    guard let data = try? await ClickDropService.loadOriginalData(url),
                          let natural = ClickDropService.thumbnail(data, maxPixels: 1600),
                          let lookData = look.render(jpeg: data, maxDimension: 1600),
                          let looked = UIImage(data: lookData) else { return (drop.id, nil) }
                    return (drop.id, RecapPhoto(natural: natural, look: looked))
                }
            }
            for await (id, photo) in group {
                if let photo { photos[id] = photo } else { failed.insert(id) }
            }
        }
    }

    /// The first time a drop shows it develops on screen (its photo resolves out of its pixels):
    /// a light haptic, and it won't play again this visit.
    private func present(_ drop: EventDrop) async {
        guard photos[drop.id] != nil, !developedOnScreen.contains(drop.id) else { return }
        developedOnScreen.insert(drop.id)
        ClickHaptics.impact(.light)
    }

    private func delete(_ drop: EventDrop) async {
        do {
            try await env.beacons.deleteEventDrop(beaconID: beaconID, dropID: drop.id)
            photos[drop.id] = nil
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
