import SwiftUI

/// An event's recap: its drops for the grid, and the story they play as. Every drop opens
/// pixelated and develops when you tap it; drops you developed before open developed (from this
/// device when it kept them). Each drop wears its own look, the same on every device, and
/// "Natural" shows them all untouched, in the grid and the story alike.
///
/// A drop's photo only ever comes from its original once this viewer has developed it: one
/// fetched ahead for a tap stays as bytes, never decoded, until that tap.
@Observable
@MainActor
final class EventRecapModel: DropStorySource {
    let beaconID: String
    private let env: AppEnvironment

    var state = ModuleState<EventDropsState>()
    /// Every photo untouched instead of in its look. Both are drawn as each photo decodes, so
    /// switching swaps pictures already in hand.
    var natural = false
    /// The drop last shown in the story (or opened from the grid), so the grid keeps it in view.
    var selectedID: String?

    /// Full-size photos for the story, a few at a time (each is several megabytes decoded).
    private var full = RecapPhotoCache(limit: 6)
    /// The grid's small copies.
    private var thumbs = RecapPhotoCache(limit: 60)
    /// Originals fetched ahead for drops not developed yet: a tap shows them at once.
    @ObservationIgnored private var prepared: [String: Data] = [:]
    /// Each original's load while it's running (one at a time, shared).
    @ObservationIgnored private var loads: [String: Task<Data?, Never>] = [:]
    /// Tapped, photo still on its way.
    private var developing: Set<String> = []
    /// Drops whose photos this device kept (it keeps them only once developed).
    private var onDisk: Set<String> = []
    private var failed: Set<String> = []
    /// Developed just now: each resolves out of its pixels once.
    private var fresh: Set<String> = []
    @ObservationIgnored private var reportedOpen = false

    private static let fullPixels: CGFloat = 1600
    private static let thumbPixels: CGFloat = 400

    init(beaconID: String, env: AppEnvironment) {
        self.beaconID = beaconID
        self.env = env
        // Opened from the event or Home's card, the drops are usually here already: paint them now.
        state.seed(env.beaconExtras.cached(cacheKey))
        noteDisk(drops)
    }

    private var cacheKey: String { BeaconExtrasCache.eventDrops(beaconID) }
    private var userID: String? { env.session.currentSession?.userId }

    var drops: [EventDrop] { state.value?.drops ?? [] }

    private func drop(_ id: String) -> EventDrop? { drops.first { $0.id == id } }

    /// The grid's order: as they were taken.
    var timeline: [EventDrop] {
        drops.enumerated()
            .sorted { ($0.element.createdAt ?? .distantPast, $0.offset) < ($1.element.createdAt ?? .distantPast, $1.offset) }
            .map(\.element)
    }

    /// Something still to develop: the recap opens on its story.
    var hasUndeveloped: Bool { drops.contains { !isDeveloped($0.id) } }

    func load() async {
        state.begin()
        do {
            let loaded = try await env.beaconExtras.loadEventDrops(beaconID, env: env)
            noteDisk(loaded.drops)
            state.succeed(loaded)
            if loaded.phase == .revealed, !loaded.drops.isEmpty, !reportedOpen {
                reportedOpen = true
                await env.productTelemetry.track(.recapOpened)
            }
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    // MARK: - Chapters

    /// A chapter per person, yours first, then in the order their first drop was taken.
    var chapterKeys: [String] {
        var seen = Set<String>()
        let people = timeline.filter { seen.insert($0.userID).inserted }
        return (people.filter(\.isMine) + people.filter { !$0.isMine }).map(\.userID)
    }

    func chapterKey(of id: String) -> String? { drop(id)?.userID }

    func chapter(_ key: String) -> [String] { timeline.filter { $0.userID == key }.map(\.id) }

    /// A person's story opens on their first drop still to develop.
    func chapterStart(_ key: String) -> String? {
        let ids = chapter(key)
        return ids.first { !isDeveloped($0) } ?? ids.first
    }

    var nextChapterLabel: String { "Next person" }

    // MARK: - Pages

    func page(_ id: String) -> DropStoryPage? {
        guard let drop = drop(id) else { return nil }
        var subtitle = drop.createdAt?.formatted(date: .omitted, time: .shortened)
        if !natural, isDeveloped(id) {
            subtitle = [subtitle, drop.look.name].compactMap(\.self).joined(separator: " · ")
        }
        let aspect: CGFloat? = if let w = drop.width, let h = drop.height, w > 0, h > 0 { CGFloat(w) / CGFloat(h) } else { nil }
        return DropStoryPage(id: drop.id, userID: drop.userID, userName: drop.userName, avatarURL: drop.avatarURL,
                             isMine: drop.isMine, previewURL: drop.previewURL, subtitle: subtitle, aspect: aspect)
    }

    /// Developed: the server says so, or this device kept its photo (kept only once developed), so
    /// a tap is remembered across launches even before the server hears of it.
    func isDeveloped(_ id: String) -> Bool {
        onDisk.contains(id) || drop(id)?.developedAt != nil
    }

    func status(_ id: String) -> (title: String, systemImage: String) {
        if developing.contains(id) { return ("Developing…", "sparkles") }
        if failed.contains(id) {
            return (isDeveloped(id) ? "Couldn't load it. Tap to retry." : "Couldn't develop. Tap to retry.", "arrow.clockwise")
        }
        return isDeveloped(id) ? ("Opening…", "sparkles") : ("Tap to develop", "sparkles")
    }

    func open(_ id: String) async { selectedID = id }

    /// Undeveloped drops just ahead have their originals fetched, so their tap develops at once.
    func prepare(_ ids: [String]) {
        prepared = prepared.filter { ids.contains($0.key) }
        for id in ids where !isDeveloped(id) && prepared[id] == nil && loads[id] == nil {
            guard let url = drop(id)?.originalURL else { continue }
            Task {
                let data = await load(id) { await Self.download(url) }
                if let data, !isDeveloped(id), !developing.contains(id) { prepared[id] = data }
            }
        }
    }

    func tapDevelops(_ id: String) -> Bool { !isDeveloped(id) || failed.contains(id) }

    /// The tap. The original is usually in hand and develops at once while the server records
    /// the develop alongside; otherwise it's fetched (freshly signed by that develop if need be).
    /// On a drop that couldn't load, it tries again.
    func develop(_ id: String) async {
        guard let drop = drop(id), !developing.contains(id) else { return }
        failed.remove(id)
        if isDeveloped(id) {
            _ = await fullPhoto(id)
            return
        }
        developing.insert(id)
        defer { developing.remove(id) }
        let recording = Task { await record(id) }
        var data = prepared.removeValue(forKey: id)
        if data == nil, let url = drop.originalURL { data = await load(id) { await Self.download(url) } }
        if data == nil, let url = await recording.value { data = await load(id) { await Self.download(url) } }
        guard let data, let photo = await Self.decode(data, look: drop.look, maxPixels: Self.fullPixels) else {
            failed.insert(id)
            return
        }
        keep(data, for: id)
        full.insert(photo, for: id)
        fresh.insert(id)
    }

    // MARK: - Photos

    func cachedPhoto(_ id: String) -> RecapPhoto? {
        guard isDeveloped(id) else { return nil }
        return full[id] ?? thumbs[id]
    }

    /// The grid's copy, decoded on demand (developed drops only).
    func thumb(_ id: String) -> RecapPhoto? { isDeveloped(id) ? thumbs[id] ?? full[id] : nil }

    func fullPhoto(_ id: String) async -> RecapPhoto? {
        await photo(id, maxPixels: Self.fullPixels, into: \.full)
    }

    func loadThumb(_ id: String) async {
        guard thumbs[id] == nil else { return }
        _ = await photo(id, maxPixels: Self.thumbPixels, into: \.thumbs)
    }

    func image(_ photo: RecapPhoto) -> UIImage { natural ? photo.natural : photo.look }

    func isSaved(_ id: String) -> Bool { onDisk.contains(id) }
    func isFresh(_ id: String) -> Bool { fresh.contains(id) }
    func consumeFresh(_ id: String) -> Bool { fresh.remove(id) != nil }

    private func photo(_ id: String, maxPixels: CGFloat, into cache: ReferenceWritableKeyPath<EventRecapModel, RecapPhotoCache>) async -> RecapPhoto? {
        if let photo = self[keyPath: cache][id] { return photo }
        guard isDeveloped(id), let drop = drop(id) else { return nil }
        guard let data = await original(drop), let photo = await Self.decode(data, look: drop.look, maxPixels: maxPixels) else {
            failed.insert(id)
            return nil
        }
        failed.remove(id)
        self[keyPath: cache].insert(photo, for: id)
        return photo
    }

    /// A developed drop's original: from this device, else its signed URL (then kept). Without
    /// one (an older server), or once it lapsed (they last ten minutes), developing it again
    /// (idempotent) signs a fresh one.
    private func original(_ drop: EventDrop) async -> Data? {
        guard let userID else { return nil }
        let id = drop.id
        return await load(id) {
            if self.onDisk.contains(id), let data = await Task.detached(priority: .userInitiated, operation: { DropPhotoCache.data(id, userID: userID) }).value {
                return data
            }
            if let url = self.drop(id)?.originalURL, let data = await Self.download(url) {
                self.keep(data, for: id)
                return data
            }
            guard let url = await self.record(id), let data = await Self.download(url) else { return nil }
            self.keep(data, for: id)
            return data
        }
    }

    /// One load per drop at a time, shared by whoever needs it.
    private func load(_ id: String, _ work: @escaping @MainActor () async -> Data?) async -> Data? {
        if let running = loads[id] { return await running.value }
        let task = Task { await work() }
        loads[id] = task
        let data = await task.value
        if loads[id] == task { loads[id] = nil }
        return data
    }

    private nonisolated static func download(_ url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) { try? await ClickDropService.loadOriginalData(url) }.value
    }

    private nonisolated static func decode(_ data: Data, look: ClickDropFilter, maxPixels: CGFloat) async -> RecapPhoto? {
        await Task.detached(priority: .userInitiated) { RecapPhoto.make(data, look: look, maxPixels: maxPixels) }.value
    }

    private func noteDisk(_ drops: [EventDrop]) {
        guard let userID else { return }
        let found = drops.map(\.id).filter { !onDisk.contains($0) && DropPhotoCache.exists($0, userID: userID) }
        if !found.isEmpty { onDisk.formUnion(found) }
    }

    /// Developed photos stay on this device: every later open (and launch) shows them at once.
    private func keep(_ data: Data, for id: String) {
        guard let userID, !onDisk.contains(id) else { return }
        onDisk.insert(id)
        Task.detached(priority: .utility) { DropPhotoCache.save(data, dropID: id, userID: userID) }
    }

    /// The server's half of the tap: records this viewer's develop and returns a freshly signed original.
    private func record(_ id: String) async -> URL? {
        guard let result = try? await env.drops.develop([ClickDropRef(kind: .event, id: id)]).first(where: { $0.ref.id == id }),
              result.status == .developed else { return nil }
        markDeveloped(id, at: result.developedAt ?? .now)
        return result.originalURL
    }

    /// Records a develop on the drops everyone shares, so the event page and the next open agree.
    private func markDeveloped(_ id: String, at date: Date) {
        guard var current = state.value, let i = current.drops.firstIndex(where: { $0.id == id }),
              current.drops[i].developedAt == nil else { return }
        current.drops[i].developedAt = date
        state.succeed(current)
        env.beaconExtras.seed(current, for: cacheKey)
    }

    // MARK: - Delete and report

    var deleteMessage: String { "It's removed from the recap for everyone." }

    func delete(_ id: String) async throws {
        try await env.beacons.deleteEventDrop(beaconID: beaconID, dropID: id)
        guard var current = state.value else { return }
        current.drops.removeAll { $0.id == id }
        state.succeed(current)
        env.beaconExtras.seed(current, for: cacheKey)
    }

    func report(_ id: String, reason: String) async throws {
        try await env.beacons.reportDrop(ClickDropRef(kind: .event, id: id), reason: reason)
    }

    // MARK: - Footer

    func footer(_ id: String, live: Bool, shown: Bool, interaction: DropStoryInteraction) -> some View {
        EventRecapControls(model: self, interaction: interaction)
    }

    func showPeople() {
        env.router.navigate(to: .eventPeople(beaconID: beaconID))
    }
}

/// A recap photo in its look and untouched, decoded together so "Natural" never waits.
struct RecapPhoto: Sendable {
    let natural: UIImage
    let look: UIImage

    /// Decoded and rendered off the main actor; nil when the bytes aren't an image.
    nonisolated static func make(_ data: Data, look: ClickDropFilter, maxPixels: CGFloat) -> RecapPhoto? {
        guard let natural = ClickDropService.thumbnail(data, maxPixels: maxPixels),
              let looked = look.renderImage(jpeg: data, maxDimension: maxPixels) else { return nil }
        return RecapPhoto(natural: natural, look: looked)
    }
}

/// The most recently used photos, up to `limit`.
struct RecapPhotoCache {
    let limit: Int
    private var photos: [String: RecapPhoto] = [:]
    private var order: [String] = []

    init(limit: Int) { self.limit = limit }

    subscript(id: String) -> RecapPhoto? { photos[id] }

    mutating func insert(_ photo: RecapPhoto, for id: String) {
        photos[id] = photo
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > limit { photos[order.removeFirst()] = nil }
    }
}

/// Under each drop in the story, the same on every page: "Natural" and who was there.
private struct EventRecapControls: View {
    @Bindable var model: EventRecapModel
    let interaction: DropStoryInteraction

    var body: some View {
        HStack(spacing: 12) {
            Button { model.natural.toggle() } label: {
                Label("Natural", systemImage: "camera.filters")
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(model.natural ? ClickColors.primaryActionForeground : .white)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassCircleBackground(tint: model.natural ? ClickColors.primaryActionFill : nil)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.natural ? .isSelected : [])
            .accessibilityHint("Shows every photo without its look.")
            Spacer(minLength: 0)
            Button {
                interaction.close { model.showPeople() }
            } label: {
                Label("Who was there", systemImage: "person.2")
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassCircleBackground()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .glassGroup()
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}
