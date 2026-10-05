import SwiftUI
import UIKit

/// Shared Click Drops for the session: the Home strip, the archive and the story viewer read and
/// write this one store, so a drop developed or reacted to in any of them is already there in the others.
///
/// Lives on the environment: Home is lazy, so the strip is rebuilt whenever it scrolls back into
/// view, and it must come back exactly as it was (no blank, no reload).
@Observable
@MainActor
final class SharedDropsStore {
    struct PendingShare: Identifiable, Equatable {
        let id = UUID()
        let jpeg: Data
        let audience: SharedDrop.Audience
        let caption: String?
        var failed = false
    }

    var drops = ModuleState<[SharedDrop]>()
    /// Developed photos for the strip's tiles (decoded small), by drop ID: only the people's covers
    /// stay in memory; the viewer reads the rest from disk as it plays.
    var originals: [String: UIImage] = [:]
    /// Every drop you can see, newest first, a page at a time (Home's "View all").
    var archive = ModuleState<SharedDropArchivePage>()
    var archiveMoreFailed = false
    /// Developed photos for archive tiles, decoded at grid size; bounded (see `rememberThumb`).
    var thumbs: [String: UIImage] = [:]
    var developing: Set<String> = []
    /// Developed in the viewer just now: it plays the unveil once.
    var freshlyDeveloped: Set<String> = []
    var uploads: [PendingShare] = []
    var message: String?
    var fetchedAt: Date?
    /// Set by Home's menu: the strip opens its camera (it owns the capture flow).
    var cameraRequested = false

    nonisolated static let tilePixels: CGFloat = 720
    nonisolated static let gridPixels: CGFloat = 400
    nonisolated static let viewerPixels: CGFloat = 2048
    private static let cacheKey = "shared-drops"
    private static let archiveCacheKey = "shared-drops-archive"
    /// Archive tiles kept decoded: a few screens of grid either way of where you are.
    private static let thumbLimit = 120

    /// The strip, one tile per person.
    var groups: [SharedDropGroup] { SharedDropGroup.group(drops.value ?? []) }
    func group(_ userID: String) -> SharedDropGroup? { groups.first { $0.userID == userID } }

    /// Archive drops that can be opened (developed or ready), in grid order.
    var archiveViewable: [SharedDrop] { (archive.value?.drops ?? []).filter { !$0.state().isPending } }

    /// The strip's copy first (it's the fresher one), else the archive's.
    func drop(_ id: String) -> SharedDrop? {
        drops.value?.first { $0.id == id } ?? archive.value?.drops.first { $0.id == id }
    }

    /// The photos the strip shows: each person's cover.
    private var coverIDs: Set<String> { Set(groups.map(\.cover.id)) }

    // MARK: - Loading

    /// The tiles on screen when Home opens: their photos are decoded before its first frame.
    private static let firstScreenTiles = 4

    /// Paints the last strip from disk synchronously, before the shell's first frame: Home opens
    /// with the strip exactly as it was, instead of tiles, previews and photos landing in turns
    /// after launch. Photos past the first screen follow off-main (out of view).
    func restore(userID: String) {
        guard drops.value == nil, let cached = CacheStore.loadNow([SharedDrop].self, key: Self.cacheKey, userID: userID) else { return }
        let list = cached.map { var drop = $0; drop.originalURL = nil; return drop }
        for group in SharedDropGroup.group(list).prefix(Self.firstScreenTiles) where group.cover.state() == .developed {
            originals[group.cover.id] = SharedDropPhotoCache.load(group.cover.id, userID: userID, maxPixels: Self.tilePixels)
        }
        drops.seed(list)
        restoredSeed = cached
        if let page = CacheStore.loadNow(SharedDropArchivePage.self, key: Self.archiveCacheKey, userID: userID) {
            archive.seed(SharedDropArchivePage(drops: page.drops.map { var drop = $0; drop.originalURL = nil; return drop }, nextBefore: page.nextBefore))
        }
    }

    /// Set by `restore`: `load` seeds reactions and the remaining photos from it.
    private var restoredSeed: [SharedDrop]?

    /// Paints the last strip (and its developed photos) from disk at once, then refreshes.
    /// One request: the server inlines originals and reactions for drops already developed.
    func load(env: AppEnvironment) async {
        let userID = env.session.currentSession?.userId
        if let restored = restoredSeed, let userID {
            restoredSeed = nil
            seedReactions(restored, env: env)
            await paintFromDisk(restored, userID: userID)
        } else if drops.value == nil, let userID, let cached = await CacheStore.shared.load([SharedDrop].self, key: Self.cacheKey, userID: userID) {
            drops.seed(cached.map { var drop = $0; drop.originalURL = nil; return drop })
            seedReactions(cached, env: env)
            await paintFromDisk(cached, userID: userID)
        }
        // Scrolling back into view reuses what's shown; only a stale strip refetches.
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < SelfDataStore.freshFor { return }
        drops.begin()
        do {
            let loaded = try await env.drops.sharedDrops()
            commit(loaded, env: env)
            fetchedAt = .now
            seedReactions(loaded, env: env)
            if let userID {
                let keep = Set(loaded.map(\.id)).union((archive.value?.drops ?? []).map(\.id))
                await Task.detached(priority: .utility) { SharedDropPhotoCache.prune(keeping: keep, userID: userID) }.value
                await paintFromDisk(loaded, userID: userID)
            }
            // Developed elsewhere (another device) or never cached: download every inline original
            // to disk now, so each story plays from disk without waiting.
            await withTaskGroup(of: Void.self) { group in
                for drop in loaded where drop.state() == .developed {
                    guard let url = drop.originalURL, let userID, !SharedDropPhotoCache.exists(drop.id, userID: userID) else { continue }
                    group.addTask { _ = await self.fetchOriginal(url, dropID: drop.id, userID: userID) }
                }
            }
        } catch {
            if !error.isCancellation { drops.fail(error.userFacingMessage) }
        }
        // The archive's first page loads behind the strip, so "View all" opens already filled.
        await loadArchive(env: env)
    }

    // MARK: - Archive

    private var archiveFetchedAt: Date?
    private var archiveLoadingMore = false
    /// Bumped by every first-page load, so a page that lands after a refresh is dropped.
    private var archiveGeneration = 0

    /// The first page: from memory or disk at once, refetched only when stale (or `force`d).
    func loadArchive(env: AppEnvironment, force: Bool = false) async {
        let userID = env.session.currentSession?.userId
        if archive.value == nil, let userID,
           let cached = await CacheStore.shared.load(SharedDropArchivePage.self, key: Self.archiveCacheKey, userID: userID) {
            archive.seed(SharedDropArchivePage(drops: cached.drops.map { var drop = $0; drop.originalURL = nil; return drop }, nextBefore: cached.nextBefore))
        }
        if !force, let archiveFetchedAt, Date().timeIntervalSince(archiveFetchedAt) < SelfDataStore.freshFor { return }
        archiveGeneration += 1
        let generation = archiveGeneration
        archive.begin()
        do {
            let page = try await env.drops.sharedDropArchive(before: nil)
            guard generation == archiveGeneration else { return }
            seedReactions(page.drops, env: env)
            commitArchive(page, env: env)
            archiveFetchedAt = .now
            archiveMoreFailed = false
            // The first screen of tiles is decoded before the grid is opened.
            if let userID { await prefetchThumbs(page.drops.prefix(Self.firstGridTiles), userID: userID) }
        } catch {
            if !error.isCancellation { archive.fail(error.userFacingMessage) }
        }
    }

    /// The grid's first screen (three columns, five rows).
    private static let firstGridTiles = 15

    /// The next page, appended once (called as the grid nears its end).
    func loadMoreArchive(env: AppEnvironment) async {
        guard !archiveLoadingMore, let page = archive.value, let cursor = page.nextBefore else { return }
        archiveLoadingMore = true
        defer { archiveLoadingMore = false }
        let generation = archiveGeneration
        do {
            let next = try await env.drops.sharedDropArchive(before: cursor)
            guard generation == archiveGeneration, var current = archive.value else { return }
            seedReactions(next.drops, env: env)
            let shown = Set(current.drops.map(\.id))
            current.drops += next.drops.filter { !shown.contains($0.id) }
            current.nextBefore = next.nextBefore
            archive.succeed(current)
            archiveMoreFailed = false
            if let userID = env.session.currentSession?.userId { await prefetchThumbs(next.drops.prefix(Self.firstGridTiles), userID: userID) }
        } catch {
            if !error.isCancellation { archiveMoreFailed = true }
        }
    }

    private func commitArchive(_ page: SharedDropArchivePage, env: AppEnvironment) {
        archive.succeed(page)
        guard let userID = env.session.currentSession?.userId else { return }
        Task { await CacheStore.shared.save(page, key: Self.archiveCacheKey, userID: userID) }
    }

    /// An archive tile's photo: decoded from disk, else downloaded once (its bytes kept on disk).
    func loadThumb(_ drop: SharedDrop, env: AppEnvironment) async {
        guard drop.state() == .developed, thumbs[drop.id] == nil, let userID = env.session.currentSession?.userId else { return }
        await prefetchThumbs([drop], userID: userID)
    }

    /// Archive photos being loaded, so a tile and the prefetch never fetch the same one twice.
    private var thumbsLoading: Set<String> = []

    /// Loads the archive photos for the tiles after `index` (a few rows ahead of the scroll).
    func prefetchThumbs(after index: Int, env: AppEnvironment) {
        guard let list = archive.value?.drops, let userID = env.session.currentSession?.userId else { return }
        let ahead = list.dropFirst(index + 1).prefix(Self.thumbsAhead)
        Task { await prefetchThumbs(ahead, userID: userID) }
    }

    private static let thumbsAhead = 12

    private func prefetchThumbs(_ list: some Sequence<SharedDrop>, userID: String) async {
        let wanted = list.filter { $0.state() == .developed && thumbs[$0.id] == nil && !thumbsLoading.contains($0.id) }
        guard !wanted.isEmpty else { return }
        thumbsLoading.formUnion(wanted.map(\.id))
        defer { thumbsLoading.subtract(wanted.map(\.id)) }
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for drop in wanted {
                let id = drop.id, url = drop.originalURL
                group.addTask {
                    if let image = await Task.detached(priority: .userInitiated, operation: {
                        SharedDropPhotoCache.load(id, userID: userID, maxPixels: Self.gridPixels)
                    }).value {
                        return (id, image)
                    }
                    guard let url, let data = try? await ClickDropService.loadOriginalData(url) else { return (id, nil) }
                    return (id, await Task.detached(priority: .userInitiated) {
                        SharedDropPhotoCache.save(data, dropID: id, userID: userID)
                        return ClickDropService.thumbnail(data, maxPixels: Self.gridPixels)
                    }.value)
                }
            }
            for await (id, image) in group {
                if let image { rememberThumb(image, for: id) }
            }
        }
    }

    /// Order thumbs were last added, oldest first, for eviction.
    private var thumbOrder: [String] = []

    private func rememberThumb(_ image: UIImage, for id: String) {
        thumbs[id] = image
        thumbOrder.removeAll { $0 == id }
        thumbOrder.append(id)
        while thumbOrder.count > Self.thumbLimit { thumbs[thumbOrder.removeFirst()] = nil }
    }

    /// Decodes the covers' photos (other drops are read from disk as the viewer reaches them).
    private func paintFromDisk(_ list: [SharedDrop], userID: String) async {
        let covers = Set(SharedDropGroup.group(list).map(\.cover.id))
        for drop in list where covers.contains(drop.id) && drop.state() == .developed && originals[drop.id] == nil {
            let id = drop.id
            if let image = await Task.detached(priority: .userInitiated, operation: {
                SharedDropPhotoCache.load(id, userID: userID, maxPixels: Self.tilePixels)
            }).value {
                originals[id] = image
            }
        }
    }

    /// Reactions arrive with the strip, so the viewer opens with them in place (no separate load).
    private func seedReactions(_ list: [SharedDrop], env: AppEnvironment) {
        for drop in list {
            if let reactions = drop.reactions { env.beaconExtras.seed(reactions, for: BeaconExtrasCache.reactions(.sharedDrop, drop.id)) }
        }
    }

    /// Downloads an original once and keeps its bytes on disk; a cover (or a drop not cached on
    /// disk) also keeps a tile-sized copy in memory. False when the download failed.
    @discardableResult
    private func fetchOriginal(_ url: URL, dropID: String, userID: String?) async -> Bool {
        guard let data = try? await ClickDropService.loadOriginalData(url) else { return false }
        let keepsTile = userID == nil || coverIDs.contains(dropID)
        let image = await Task.detached(priority: .userInitiated) {
            if let userID { SharedDropPhotoCache.save(data, dropID: dropID, userID: userID) }
            return keepsTile ? ClickDropService.thumbnail(data, maxPixels: Self.tilePixels) : nil
        }.value
        if let image { originals[dropID] = image }
        return true
    }

    /// The viewer's full-size photo: from disk when it's been seen before, otherwise downloaded once.
    func fullImage(for drop: SharedDrop, env: AppEnvironment) async -> UIImage? {
        let userID = env.session.currentSession?.userId
        let id = drop.id
        if let userID, let image = await Task.detached(priority: .userInitiated, operation: {
            SharedDropPhotoCache.load(id, userID: userID, maxPixels: Self.viewerPixels)
        }).value {
            return image
        }
        let url: URL?
        if let inline = drop.originalURL {
            url = inline
        } else {
            url = try? await env.drops.develop([ClickDropRef(kind: .shared, id: id)]).first?.originalURL
        }
        guard let url, await fetchOriginal(url, dropID: id, userID: userID), let userID else { return originals[id] }
        return await Task.detached(priority: .userInitiated) {
            SharedDropPhotoCache.load(id, userID: userID, maxPixels: Self.viewerPixels)
        }.value
    }

    // MARK: - Writes

    private func commit(_ list: [SharedDrop], env: AppEnvironment) {
        drops.succeed(list)
        // Every change to the strip is the next launch's first paint.
        guard let userID = env.session.currentSession?.userId else { return }
        Task { await CacheStore.shared.save(list, key: Self.cacheKey, userID: userID) }
    }

    /// Develops ready drops (idempotent on the server) and fetches their originals.
    /// `fresh`: opened in the viewer, which plays the unveil.
    func develop(_ targets: [SharedDrop], fresh: Bool = false, env: AppEnvironment) async {
        let ready = targets.filter { $0.state() == .ready && !developing.contains($0.id) }
        guard !ready.isEmpty else { return }
        developing.formUnion(ready.map(\.id))
        defer { developing.subtract(ready.map(\.id)) }
        let userID = env.session.currentSession?.userId
        do {
            let results = try await env.drops.develop(ready.map { ClickDropRef(kind: .shared, id: $0.id) })
            await withTaskGroup(of: Void.self) { group in
                for result in results where result.status == .developed {
                    guard let url = result.originalURL else { continue }
                    group.addTask { _ = await self.fetchOriginal(url, dropID: result.ref.id, userID: userID) }
                }
            }
            var updated = drops.value ?? []
            var archived = archive.value
            for result in results where result.status == .developed {
                let at = result.developedAt ?? .now
                if let index = updated.firstIndex(where: { $0.id == result.ref.id }) { updated[index].developedAt = at }
                if let index = archived?.drops.firstIndex(where: { $0.id == result.ref.id }) { archived?.drops[index].developedAt = at }
                if fresh { freshlyDeveloped.insert(result.ref.id) }
            }
            withAnimation(ClickMotion.subtleFade) {
                if drops.value != nil { commit(updated, env: env) }
                if let archived { commitArchive(archived, env: env) }
            }
            if let userID {
                // Watching moves a person's cover on to their next drop: its photo is ready on the tile.
                await paintFromDisk(updated, userID: userID)
                for result in results where result.status == .developed && thumbs[result.ref.id] == nil {
                    let id = result.ref.id
                    if let image = await Task.detached(priority: .userInitiated, operation: {
                        SharedDropPhotoCache.load(id, userID: userID, maxPixels: Self.gridPixels)
                    }).value { rememberThumb(image, for: id) }
                }
            }
        } catch {
            if !error.isCancellation { message = "Couldn't develop right now. Try again in a moment." }
        }
    }

    func remove(_ dropID: String, env: AppEnvironment) {
        commit((drops.value ?? []).filter { $0.id != dropID }, env: env)
        if var page = archive.value {
            page.drops.removeAll { $0.id == dropID }
            commitArchive(page, env: env)
        }
        originals[dropID] = nil
        thumbs[dropID] = nil
    }

    func share(_ upload: PendingShare, env: AppEnvironment) async {
        do {
            let drop = try await env.drops.shareDrop(upload.jpeg, audience: upload.audience, caption: upload.caption, clientDropID: upload.id)
            uploads.removeAll { $0.id == upload.id }
            commit([drop] + (drops.value ?? []).filter { $0.id != drop.id }, env: env)
            if var page = archive.value {
                page.drops = [drop] + page.drops.filter { $0.id != drop.id }
                commitArchive(page, env: env)
            }
            message = nil
            ClickHaptics.success()
        } catch let refusal as SharedDropPostError {
            uploads.removeAll { $0.id == upload.id }
            message = refusal.errorDescription
        } catch {
            guard !error.isCancellation else { return }
            if let index = uploads.firstIndex(where: { $0.id == upload.id }) { uploads[index].failed = true }
            message = "Couldn't share your drop. Tap Retry — it won't be shared twice."
        }
    }

    func retry(_ upload: PendingShare, env: AppEnvironment) async {
        guard let index = uploads.firstIndex(where: { $0.id == upload.id }) else { return }
        uploads[index].failed = false
        await share(uploads[index], env: env)
    }
}
