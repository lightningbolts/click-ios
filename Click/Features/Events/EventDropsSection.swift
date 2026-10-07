import SwiftUI

/// Event Click Drops on an event's detail (spec F1): during the event, checked-in people add up to
/// ten photos that all develop together the next morning; afterwards, the recap. Everything shown
/// here is what the server says this viewer may see.
struct EventDropsSection: View {
    @Environment(AppEnvironment.self) private var env

    let beacon: MapBeacon

    @State private var state = ModuleState<EventDropsState>()
    @State private var showingCamera = false
    /// The photo just taken, held until the camera is gone so its tile arrives on screen.
    @State private var captured: Data?
    /// Uploads in flight or failed, newest last. A failed one keeps its photo and ID for a safe retry.
    @State private var uploads: [PendingUpload] = []
    /// Drops posted from this screen, by the upload they came from: the tile keeps its identity
    /// and develops in place instead of being swapped for a new one.
    @State private var landed: [String: UUID] = [:]
    @State private var confirmDelete: EventDrop?
    @State private var message: String?

    struct PendingUpload: Identifiable, Equatable {
        let id = UUID()
        let jpeg: Data
        var failed = false
    }

    /// One tile in your strip: a posted drop, or an upload still on its way.
    private enum Tile: Identifiable {
        case drop(EventDrop, id: String)
        case upload(PendingUpload)

        var id: String {
            switch self {
            case .drop(_, let id): id
            case .upload(let upload): upload.id.uuidString
            }
        }
    }

    var body: some View {
        // A container that always exists, so the load runs even while there's nothing to show.
        VStack(spacing: 0) {
            if let current = state.value, isRelevant(current) {
                content(current)
            }
        }
        .onAppear { state.seed(env.beaconExtras.cached(BeaconExtrasCache.eventDrops(beacon.id))) }
        .task(id: beacon.id) { await load() }
        .fullScreenCover(isPresented: $showingCamera, onDismiss: startCapturedUpload) {
            ClickDropCameraView(
                endsAt: state.value?.closesAt,
                subtitle: EventDropsState.developsCaption(state.value?.revealAt),
                showsLooks: false
            ) { draft in captured = draft.data }
        }
        .confirmation("Delete this drop?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                      keep: "Keep It") {
            Button("Delete", role: .destructive) {
                if let drop = confirmDelete { Task { await delete(drop) } }
            }
        }
    }

    /// Hidden entirely for people who weren't there and can't post (nothing to show them).
    private func isRelevant(_ current: EventDropsState) -> Bool {
        current.canPost || !current.drops.isEmpty || !uploads.isEmpty
            || (current.access != .none && current.phase == .revealed)
    }

    private func content(_ current: EventDropsState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(current.access == .absentee && current.phase == .revealed ? "What you missed" : "Click Drops")
                    .font(ClickTypography.sectionTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(caption(current))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }
            if hasCard(current) {
                // The page's card style, like the info, people and hosting cards.
                card(current)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .detailCard()
            }
        }
    }

    private func hasCard(_ current: EventDropsState) -> Bool {
        (current.phase == .revealed && !current.drops.isEmpty)
            || (current.phase != .revealed && (!current.myDrops.isEmpty || !uploads.isEmpty))
            || current.canPost || !current.myDrops.isEmpty || message != nil
    }

    private func card(_ current: EventDropsState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if current.phase == .revealed, !current.drops.isEmpty {
                Button {
                    env.router.navigate(to: .eventRecap(beaconID: beacon.id))
                } label: {
                    Label("Open the recap", systemImage: "sparkles")
                        .font(ClickTypography.button)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
            }

            if current.phase != .revealed, !current.myDrops.isEmpty || !uploads.isEmpty {
                strip(current)
                    .transition(.opacity)
            }

            // Uploads on their way already count against what's left.
            let remaining = current.remaining - uploads.count
            if current.canPost, remaining > 0 {
                Button {
                    showingCamera = true
                } label: {
                    Label("Add a drop · \(remaining) left", systemImage: "camera")
                        .contentTransition(.numericText(value: Double(remaining)))
                        .font(ClickTypography.supportingEmphasized)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(ClickColors.accentForeground)
            }

            if !current.myDrops.isEmpty {
                Divider()
                Toggle("Show to people who RSVP'd but couldn't make it", isOn: Binding(
                    get: { state.value?.showToAbsentees ?? true },
                    set: { shown in Task { await setShownToAbsentees(shown) } }
                ))
                .font(ClickTypography.supporting)
                .tint(ClickColors.primaryActionFill)
            }

            if let message {
                Text(message).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
            }
        }
    }

    private func caption(_ current: EventDropsState) -> String {
        switch current.phase {
        case .before:
            return "Check in when it starts to add photos. They develop together the next morning."
        case .open:
            return EventDropsState.developsCaption(current.revealAt) + (current.canPost ? "" : ". Check in to add yours.")
        case .developing:
            return EventDropsState.developsCaption(current.revealAt)
        case .revealed:
            if current.access == .absentee { return "A few moments from the people who were there." }
            return current.drops.isEmpty ? "No drops from this one." : "Everyone's drops, developed."
        }
    }

    private static let tileSize = CGSize(width: 72, height: 96)

    private func strip(_ current: EventDropsState) -> some View {
        let tiles = current.myDrops.map { Tile.drop($0, id: landed[$0.id]?.uuidString ?? $0.id) } + uploads.map(Tile.upload)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tiles) { tile in
                        // One frame for both states, so an upload develops into its drop in place.
                        ZStack {
                            switch tile {
                            case .drop(let drop, _): thumbnail(drop).transition(.opacity)
                            case .upload(let upload): uploadTile(upload).transition(.opacity)
                            }
                        }
                        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
            // A new photo lands at the end of the strip: bring it into view.
            .onChange(of: uploads.last?.id) { _, id in
                guard let id else { return }
                withAnimation(ClickMotion.content) { proxy.scrollTo(id.uuidString, anchor: .trailing) }
            }
        }
    }

    private func thumbnail(_ drop: EventDrop) -> some View {
        PixelatedPreview(url: drop.previewURL)
            .frame(width: Self.tileSize.width, height: Self.tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = drop }
            }
            .accessibilityLabel("Your drop, developing")
            .accessibilityAction(named: "Delete") { confirmDelete = drop }
    }

    private func uploadTile(_ upload: PendingUpload) -> some View {
        UploadingDropTile(jpeg: upload.jpeg, failed: upload.failed, size: Self.tileSize, cornerRadius: 12) {
            Task { await retry(upload) }
        }
    }

    // MARK: - Loading & writes

    /// After a write: the reload must not reuse a read that started before it.
    private func reload() async {
        env.beaconExtras.invalidate(BeaconExtrasCache.eventDrops(beacon.id))
        await load()
    }

    private func load() async {
        state.begin()
        do {
            let fresh = try await env.beaconExtras.loadEventDrops(beacon.id, env: env)
            // Changes to what's already on screen (a drop added or deleted) move rather than jump.
            withAnimation(state.value == nil ? nil : ClickMotion.content) { state.succeed(fresh) }
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    /// Once the camera has gone: the photo's tile arrives in the strip and its upload starts.
    private func startCapturedUpload() {
        guard let jpeg = captured else { return }
        captured = nil
        let upload = PendingUpload(jpeg: jpeg)
        withAnimation(ClickMotion.content) {
            uploads.append(upload)
            message = nil
        }
        Task { await send(upload) }
    }

    private func send(_ upload: PendingUpload) async {
        do {
            let drop = try await env.beacons.postEventDrop(beaconID: beacon.id, clientDropID: upload.id, jpeg: upload.jpeg,
                                                           showToAbsentees: nil)
            // Its preview is here before the tile turns into it, so the photo develops in one fade.
            await PixelatedPreview.prefetch(drop.previewURL)
            withAnimation(ClickMotion.content) {
                uploads.removeAll { $0.id == upload.id }
                landed[drop.id] = upload.id
                if let current = state.value { state.succeed(current.adding(drop)) }
                message = nil
            }
            ClickHaptics.success()
            await reload()
        } catch let refusal as EventDropPostError {
            withAnimation(ClickMotion.content) {
                uploads.removeAll { $0.id == upload.id }
                message = refusal.errorDescription
            }
            await reload()
        } catch {
            guard !error.isCancellation else { return }
            withAnimation(ClickMotion.subtleFade) {
                if let index = uploads.firstIndex(where: { $0.id == upload.id }) { uploads[index].failed = true }
                message = "Couldn't upload your drop. Tap Retry — it won't be added twice."
            }
        }
    }

    private func retry(_ upload: PendingUpload) async {
        guard let index = uploads.firstIndex(where: { $0.id == upload.id }) else { return }
        withAnimation(ClickMotion.subtleFade) {
            uploads[index].failed = false
            message = nil
        }
        await send(uploads[index])
    }

    private func delete(_ drop: EventDrop) async {
        do {
            try await env.beacons.deleteEventDrop(beaconID: beacon.id, dropID: drop.id)
            await reload()
            landed[drop.id] = nil
        } catch {
            if !error.isCancellation { message = "Couldn't delete the drop. \(error.userFacingMessage)" }
        }
    }

    private func setShownToAbsentees(_ shown: Bool) async {
        do {
            try await env.beacons.setEventDropsShownToAbsentees(beaconID: beacon.id, shown)
            await reload()
        } catch {
            if !error.isCancellation { message = error.userFacingMessage }
        }
    }
}

/// A drop's server-pixelated preview (never the original), drawn with hard pixel edges. Previews
/// are immutable, so one seen before paints on the first frame (cached by object, not by token).
struct PixelatedPreview: View {
    let url: URL?
    /// Hears the preview's shape (width over height) once its image is here.
    var onAspect: (CGFloat) -> Void = { _ in }
    @State private var image: UIImage?

    private static let pixels: CGFloat = 480

    /// Loads a preview ahead, so the next view showing it paints it on its first frame.
    static func prefetch(_ url: URL?) async {
        guard let url else { return }
        _ = await ImagePipeline.shared.image(for: url, maxPixelSize: pixels, signed: true)
    }

    init(url: URL?, onAspect: @escaping (CGFloat) -> Void = { _ in }) {
        self.url = url
        self.onAspect = onAspect
        // A preview seen before paints on the first frame, even right after a cold start.
        self._image = State(initialValue: url.flatMap { ImagePipeline.shared.firstFrameImage(for: $0, maxPixelSize: Self.pixels, signed: true) })
    }

    var body: some View {
        // The fill takes the proposed size; the image fills inside it and never grows the view.
        ClickColors.fillSubtle
            .overlay {
                if let image { Image(uiImage: image).resizable().interpolation(.none).scaledToFill() }
            }
            .clipped()
            .task(id: url) {
                if image == nil, let url {
                    let loaded = await ImagePipeline.shared.image(for: url, maxPixelSize: Self.pixels, signed: true)
                    withAnimation(ClickMotion.subtleFade) { image = loaded }
                }
                if let size = image?.size, size.height > 0 { onAspect(size.width / size.height) }
            }
    }
}

/// A drop still uploading: your own photo, softly shimmering until it lands (never a spinner);
/// Retry over it if the upload failed.
struct UploadingDropTile: View {
    let jpeg: Data
    let failed: Bool
    let size: CGSize
    let cornerRadius: CGFloat
    let retry: () -> Void
    @State private var photo: UIImage?

    var body: some View {
        ClickColors.fillSubtle
            .overlay { if let photo { Image(uiImage: photo).resizable().scaledToFill().opacity(failed ? 0.45 : 0.8) } }
            .shimmering(!failed)
            .overlay {
                if failed {
                    Button(action: retry) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry").font(ClickTypography.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(8)
                        .glassCircleBackground()
                        .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Upload failed. Retry.")
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel(failed ? "Upload failed" : "Uploading your drop")
            .task {
                // Decoded off the main actor, so the tile's arrival animation never hitches.
                let jpeg = jpeg, maxPixels = max(size.width, size.height) * 3
                let decoded = await Task.detached(priority: .userInitiated) { ClickDropService.thumbnail(jpeg, maxPixels: maxPixels) }.value
                withAnimation(ClickMotion.subtleFade) { photo = decoded }
            }
    }
}
