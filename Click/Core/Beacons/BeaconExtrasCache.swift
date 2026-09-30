import Foundation

/// A beacon's live extras (listening now, reactions, alert status, event drops), kept for the
/// session so a beacon opens filled: its sections paint the last value at once and refresh behind
/// it. `prefetch` warms them as soon as a beacon is selected, before its page opens. Concurrent
/// loads of one key share a single request.
@MainActor
final class BeaconExtrasCache {
    private var values: [String: any Sendable] = [:]
    private var inFlight: [String: Task<any Sendable, any Error>] = [:]

    static func listening(_ beaconID: String) -> String { "listening:\(beaconID)" }
    static func reactions(_ target: ReactionTarget, _ id: String) -> String { "reactions:\(target.rawValue):\(id)" }
    static func alert(_ beaconID: String) -> String { "alert:\(beaconID)" }
    static func eventDrops(_ beaconID: String) -> String { "eventDrops:\(beaconID)" }

    func cached<T>(_ key: String) -> T? { values[key] as? T }

    /// Records a value a screen got from a write (a vote, a reaction), so the next open shows it.
    func store(_ value: any Sendable, for key: String) { values[key] = value }

    func load<T: Sendable>(_ key: String, _ fetch: @escaping @MainActor () async throws -> T) async throws -> T {
        let task = inFlight[key] ?? Task { @MainActor in try await fetch() as any Sendable }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let value = try await task.value
        values[key] = value
        guard let typed = value as? T else { throw CancellationError() }
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
        values.removeAll()
        inFlight.removeAll()
    }
}
