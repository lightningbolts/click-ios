import CoreLocation
import Foundation

/// A nearby discovery result: beacons and hubs around one point, fetched together so Home,
/// Map, and the Nearby sheet all read the same identities.
public struct NearbyDiscovery: Codable, Equatable, Sendable {
    public let beacons: [MapBeacon]
    public let hubs: [NearbyHub]
    public let latitude: Double
    public let longitude: Double
    public let fetchedAt: Date

    /// Real counts per beacon kind, in canonical kind order, omitting empty kinds.
    public func kindCounts(at now: Date = .now) -> [(kind: BeaconKind, count: Int)] {
        let active = beacons.filter { $0.isActive(at: now) }
        return BeaconKind.allCases.compactMap { kind in
            let count = active.filter { $0.kind == kind }.count
            return count > 0 ? (kind, count) : nil
        }
    }
}

/// Server-authoritative beacon, event, and hub reads (spec §52–§63).
public actor BeaconRepository {
    private let api: ClickAPIClient
    private let cache: CacheStore
    /// Recently seen beacons (discovery, detail, chat-card prefetch) so detail opens instantly
    /// and refreshes in the background (`CachePolicy.beaconDetail`). Session memory only.
    private var known: [String: (beacon: MapBeacon, isExpired: Bool, storedAt: Date)] = [:]
    private var prefetching: [String: Task<Void, Never>] = [:]

    /// Default discovery radius, matching the KMP Nearby feed.
    public static let discoveryRadiusMeters = 5_000

    public init(api: ClickAPIClient, cache: CacheStore = .shared) {
        self.api = api
        self.cache = cache
    }

    // MARK: - Nearby discovery

    public func cachedDiscovery(userID: String) async -> NearbyDiscovery? {
        await cache.load(NearbyDiscovery.self, key: "nearby", userID: userID)
    }

    /// Beacons (`GET /api/beacons`) and hubs (`GET /api/hub/nearby`) around a coordinate.
    /// Hubs are an enrichment: when that request fails the beacon result still stands.
    public func discovery(
        around coordinate: CLLocationCoordinate2D,
        radiusMeters: Int = BeaconRepository.discoveryRadiusMeters,
        userID: String
    ) async throws -> NearbyDiscovery {
        async let beaconsTask = nearbyBeacons(around: coordinate, radiusMeters: radiusMeters)
        async let hubsTask = nearbyHubs(around: coordinate, radiusMeters: radiusMeters)
        let beacons = try await beaconsTask
        let hubs = (try? await hubsTask) ?? []
        let result = NearbyDiscovery(
            beacons: beacons,
            hubs: hubs,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            fetchedAt: .now
        )
        await cache.save(result, key: "nearby", userID: userID)
        remember(beacons)
        return result
    }

    public func nearbyBeacons(around coordinate: CLLocationCoordinate2D, radiusMeters: Int) async throws -> [MapBeacon] {
        let request = APIRequest(
            path: "/api/beacons",
            method: .get,
            queryItems: [
                URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                URLQueryItem(name: "lon", value: String(coordinate.longitude)),
                URLQueryItem(name: "radius_meters", value: String(radiusMeters))
            ]
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try JSONFields.object(data)
        return JSONFields.rows(root["beacons"]).compactMap(MapBeacon.decode)
    }

    public func nearbyHubs(around coordinate: CLLocationCoordinate2D, radiusMeters: Int) async throws -> [NearbyHub] {
        let request = APIRequest(
            path: "/api/hub/nearby",
            method: .get,
            queryItems: [
                URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                URLQueryItem(name: "lon", value: String(coordinate.longitude)),
                URLQueryItem(name: "radius_meters", value: String(radiusMeters))
            ]
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try JSONFields.object(data)
        return JSONFields.rows(root["hubs"]).compactMap(NearbyHub.decode)
    }

    // MARK: - Saved events

    public func cachedBookmarks(userID: String) async -> [SavedEvent]? {
        await cache.load([SavedEvent].self, key: "bookmarks", userID: userID)
    }

    /// The caller's saved events, newest bookmark first (`GET /api/me/event-bookmarks`).
    public func bookmarks(userID: String) async throws -> [SavedEvent] {
        let request = APIRequest(
            path: "/api/me/event-bookmarks",
            method: .get,
            queryItems: [URLQueryItem(name: "limit", value: "100")]
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try JSONFields.object(data)
        guard root["bookmarks"] != nil else { throw APIError.decoding }
        var seen = Set<String>()
        let events = JSONFields.rows(root["bookmarks"])
            .compactMap(SavedEvent.decode)
            .filter { seen.insert($0.beaconID).inserted }
        await cache.save(events, key: "bookmarks", userID: userID)
        return events
    }

    // MARK: - Single beacon

    /// `GET /api/beacons/{id}`. Serves expired rows too (chat/profile history); `isExpired`
    /// lets callers present them as ended rather than live.
    public func beacon(id: String) async throws -> (beacon: MapBeacon, isExpired: Bool) {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(id)", method: .get))
        let root = try JSONFields.object(data)
        guard let row = JSONFields.dictionary(root["beacon"]), let beacon = MapBeacon.decode(row) else {
            throw APIError.decoding
        }
        let expired = JSONFields.bool(root["expired"]) ?? false
        known[id] = (beacon, expired, .now)
        return (beacon, expired)
    }

    // MARK: - Beacon cache (instant detail)

    /// A cached beacon and whether it is still inside its freshness window.
    public func cachedBeacon(id: String, now: Date = .now) -> (beacon: MapBeacon, isExpired: Bool, isFresh: Bool)? {
        guard let entry = known[id] else { return nil }
        return (entry.beacon, entry.isExpired, now.timeIntervalSince(entry.storedAt) < CachePolicy.beaconDetail)
    }

    /// Seeds the cache from list results without overwriting fresher detail reads.
    public func remember(_ beacons: [MapBeacon]) {
        let now = Date()
        for beacon in beacons where known[beacon.id] == nil {
            known[beacon.id] = (beacon, false, now)
        }
        if known.count > 300 {
            for key in known.sorted(by: { $0.value.storedAt < $1.value.storedAt }).prefix(known.count - 300).map(\.key) {
                known[key] = nil
            }
        }
    }

    /// Warms the detail cache when a card scrolls on screen; one request per ID at a time.
    public func prefetch(id: String) {
        guard cachedBeacon(id: id)?.isFresh != true, prefetching[id] == nil else { return }
        prefetching[id] = Task {
            _ = try? await self.beacon(id: id)
            self.finishPrefetch(id)
        }
    }

    private func finishPrefetch(_ id: String) {
        prefetching[id] = nil
    }

    /// Removes a deleted beacon everywhere this repository caches it.
    public func evict(id: String) {
        known[id] = nil
    }

    public func clearCache() {
        known.removeAll()
        prefetching.values.forEach { $0.cancel() }
        prefetching.removeAll()
    }

    /// `POST /api/beacons/image` (JSON base64, ≤2 MB, jpeg/png/webp/gif) → public URL for
    /// `metadata.image_url`.
    public func uploadImage(jpeg: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["file_b64": jpeg.base64EncodedString(), "mime_type": "image/jpeg"])
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/image", method: .post, body: body))
        guard let url = JSONFields.string(try JSONFields.object(data)["image"]) else { throw APIError.decoding }
        return url
    }

    /// `PATCH /api/beacons/{id}` (creator only): metadata is merged server-side; schedule,
    /// listing options and `show_creator_name` are top-level fields.
    public func update(id: String, json: Data) async throws -> MapBeacon {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(id)", method: .patch, body: json))
        let root = try JSONFields.object(data)
        if let row = JSONFields.dictionary(root["beacon"]), let beacon = MapBeacon.decode(row) {
            known[id] = (beacon, false, .now)
            return beacon
        }
        // Some deployments answer `{ok:true}`; read back the canonical row.
        known[id] = nil
        return try await beacon(id: id).beacon
    }

    /// `POST /api/beacons`. The server validates kind, schedule, music links, and listing policy.
    public func create(json: Data) async throws -> MapBeacon {
        do {
            let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons", method: .post, body: json))
            guard let row = JSONFields.dictionary(try JSONFields.object(data)["beacon"]), let beacon = MapBeacon.decode(row) else {
                throw APIError.decoding
            }
            return beacon
        } catch APIError.validation(_, let message?) {
            // Show the server's reason ("Event start must be in the future.") rather than a generic error.
            let reason = (try? JSONFields.object(Data(message.utf8))).flatMap { JSONFields.string($0["error"]) } ?? message
            throw BeaconCreateError(message: reason)
        }
    }
}

public struct BeaconCreateError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
