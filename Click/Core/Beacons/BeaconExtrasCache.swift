import Foundation

/// A beacon's live extras (listening now, reactions, alert status, event drops), kept for the
/// session so a beacon opens filled: its sections paint the last value at once and refresh behind
/// it. `prefetch` warms them as soon as a beacon is selected, before its page opens. Concurrent
/// loads of one key share a single request; a write (or `invalidate`) makes any read that started
/// before it stale, so an old response never lands over newer state.
@MainActor
final class BeaconExtrasCache {
    private var values: [String: any Sendable] = [:]
    private var inFlight: [String: (version: Int, task: Task<any Sendable, any Error>)] = [:]
    /// Bumped by every write to a key; a load only publishes if its key wasn't written meanwhile.
    private var versions: [String: Int] = [:]
    /// Bumped on sign-out; loads from an earlier session never publish.
    private var generation = 0

    static func listening(_ beaconID: String) -> String { "listening:\(beaconID)" }
    static func reactions(_ target: ReactionTarget, _ id: String) -> String { "reactions:\(target.rawValue):\(id)" }
    static func alert(_ beaconID: String) -> String { "alert:\(beaconID)" }
    static func eventDrops(_ beaconID: String) -> String { "eventDrops:\(beaconID)" }

    func cached<T>(_ key: String) -> T? { values[key] as? T }

    /// Records a value a screen got from a write (a vote, a reaction), so the next open shows it.
    func store(_ value: any Sendable, for key: String) {
        invalidate(key)
        values[key] = value
    }

    /// After a write whose result isn't a full value: the next load starts a fresh request.
    func invalidate(_ key: String) {
        versions[key, default: 0] += 1
        inFlight[key] = nil
    }

    /// Stale results (the key was written, or the session ended, while loading) throw
    /// `CancellationError`, which screens already ignore.
    func load<T: Sendable>(_ key: String, _ fetch: @escaping @MainActor () async throws -> T) async throws -> T {
        let version = versions[key, default: 0]
        let session = generation
        let task: Task<any Sendable, any Error>
        if let running = inFlight[key], running.version == version {
            task = running.task
        } else {
            task = Task { @MainActor in try await fetch() as any Sendable }
            inFlight[key] = (version, task)
        }
        let value = try await task.value
        if inFlight[key]?.task == task { inFlight[key] = nil }
        guard session == generation, versions[key, default: 0] == version, let typed = value as? T else { throw CancellationError() }
        values[key] = value
        return typed
    }

    /// Starts loading whatever this beacon's page will show, unless it's already cached or loading.
    func prefetch(_ beacon: MapBeacon, env: AppEnvironment) {
        let id = beacon.id
        var jobs: [(String, @MainActor () async throws -> any Sendable)] = []
        if beacon.kind == .soundtrack, env.features.isEnabled(.soundtrackPresence) {
            jobs.append((Self.listening(id), { try await env.beacons.listening(beaconID: id) }))
            jobs.append((Self.reactions(.soundtrack, id), { try await env.drops.reactions(.soundtrack, id: id) }))
        }
        if beacon.kind == .hazard, env.features.isEnabled(.alertConfirmations) {
            jobs.append((Self.alert(id), { try await env.beacons.alertState(beaconID: id) }))
        }
        if beacon.isEvent, env.features.isEnabled(.eventDrops) {
            jobs.append((Self.eventDrops(id), { try await env.beacons.eventDrops(beaconID: id) }))
        }
        for (key, fetch) in jobs where values[key] == nil && inFlight[key] == nil {
            Task { _ = try? await load(key, fetch) }
        }
    }

    func removeAll() {
        generation += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        values.removeAll()
        versions.removeAll()
    }
}
