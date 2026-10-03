import SwiftUI
import UIKit

/// Shared Click Drops for the session: the Home strip and the story viewer read and write this
/// one store, so a drop developed or reacted to in either is already there in the other.
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
    /// Developed photos for tiles (decoded small), by drop ID.
    var originals: [String: UIImage] = [:]
    var developing: Set<String> = []
    /// Developed in the viewer just now: it plays the unveil once.
    var freshlyDeveloped: Set<String> = []
    var uploads: [PendingShare] = []
    var message: String?
    var fetchedAt: Date?

    nonisolated static let tilePixels: CGFloat = 720
    nonisolated static let viewerPixels: CGFloat = 2048
    private static let cacheKey = "shared-drops"

    /// Drops that can be opened (developed or ready), in strip order: the story sequence.
    var viewable: [SharedDrop] { (drops.value ?? []).filter { !$0.state().isPending } }

    func drop(_ id: String) -> SharedDrop? { drops.value?.first { $0.id == id } }

    // MARK: - Loading

    /// Paints the last strip (and its developed photos) from disk at once, then refreshes.
    /// One request: the server inlines originals and reactions for drops already developed.
    func load(env: AppEnvironment) async {
        let userID = env.session.currentSession?.userId
        if drops.value == nil, let userID, let cached = await CacheStore.shared.load([SharedDrop].self, key: Self.cacheKey, userID: userID) {
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
                SharedDropPhotoCache.prune(keeping: Set(loaded.map(\.id)), userID: userID)
                await paintFromDisk(loaded, userID: userID)
            }
            // Developed elsewhere (another device) or never cached: fetch the inline originals.
            await withTaskGroup(of: Void.self) { group in
                for drop in loaded where drop.state() == .developed && originals[drop.id] == nil {
                    guard let url = drop.originalURL else { continue }
                    group.addTask { _ = await self.fetchOriginal(url, dropID: drop.id, userID: userID) }
                }
            }
        } catch {
            if !error.isCancellation { drops.fail(error.userFacingMessage) }
        }
    }

    private func paintFromDisk(_ list: [SharedDrop], userID: String) async {
        for drop in list where drop.state() == .developed && originals[drop.id] == nil {
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

    /// Downloads an original once, keeps its bytes on disk and a tile-sized copy in memory.
    @discardableResult
    private func fetchOriginal(_ url: URL, dropID: String, userID: String?) async -> UIImage? {
        guard let data = try? await ClickDropService.loadOriginalData(url) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            if let userID { SharedDropPhotoCache.save(data, dropID: dropID, userID: userID) }
            return ClickDropService.thumbnail(data, maxPixels: Self.tilePixels)
        }.value
        if let image { originals[dropID] = image }
        return image
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
        guard let url, await fetchOriginal(url, dropID: id, userID: userID) != nil, let userID else { return nil }
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
            for result in results where result.status == .developed {
                if let index = updated.firstIndex(where: { $0.id == result.ref.id }) {
                    updated[index].developedAt = result.developedAt ?? .now
                }
                if fresh { freshlyDeveloped.insert(result.ref.id) }
            }
            withAnimation(ClickMotion.subtleFade) { commit(updated, env: env) }
        } catch {
            if !error.isCancellation { message = "Couldn't develop right now. Try again in a moment." }
        }
    }

    func remove(_ dropID: String, env: AppEnvironment) {
        commit((drops.value ?? []).filter { $0.id != dropID }, env: env)
        originals[dropID] = nil
    }

    func share(_ upload: PendingShare, env: AppEnvironment) async {
        do {
            let drop = try await env.drops.shareDrop(upload.jpeg, audience: upload.audience, caption: upload.caption, clientDropID: upload.id)
            uploads.removeAll { $0.id == upload.id }
            commit([drop] + (drops.value ?? []).filter { $0.id != drop.id }, env: env)
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
