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
    /// Cursor for the next page of beacons (`/api/beacons` is paginated); nil once all are loaded.
    public var nextCursor: String? = nil
    /// Listed Click Places around the center (empty when Places are off or the fetch failed).
    public var places: [PlaceSummary] = []

    enum CodingKeys: String, CodingKey {
        case beacons, hubs, latitude, longitude, fetchedAt, nextCursor, places
    }

    /// Real counts per beacon kind, in canonical kind order, omitting empty kinds.
    public func kindCounts(at now: Date = .now) -> [(kind: BeaconKind, count: Int)] {
        let active = beacons.filter { $0.isActive(at: now) }
        return BeaconKind.allCases.compactMap { kind in
            let count = active.filter { $0.kind == kind }.count
            return count > 0 ? (kind, count) : nil
        }
    }
}

extension NearbyDiscovery {
    /// Cached discoveries from builds before Click Places have no `places`; they still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beacons = try container.decode([MapBeacon].self, forKey: .beacons)
        hubs = try container.decode([NearbyHub].self, forKey: .hubs)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        places = try container.decodeIfPresent([PlaceSummary].self, forKey: .places) ?? []
    }
}

/// Server-authoritative beacon, event, and hub reads (spec §52–§63).
public actor BeaconRepository {
    let api: ClickAPIClient
    private let cache: CacheStore
    /// Recently seen beacons (discovery, detail, chat-card prefetch) so detail opens instantly
    /// and refreshes in the background (`CachePolicy.beaconDetail`). Session memory only.
    /// Synchronously readable, so detail paints cached content on its first frame.
    private nonisolated let known = MemoryCache<String, KnownBeacon>()

    private struct KnownBeacon: Sendable {
        let beacon: MapBeacon
        let isExpired: Bool
        let storedAt: Date
    }
    private var prefetching: [String: Task<Void, Never>] = [:]

    /// Default discovery radius (50 km, the `/api/beacons` maximum).
    public static let discoveryRadiusMeters = 50_000
    /// Beacons per `/api/beacons` page.
    public static let discoveryPageSize = 200

    public init(api: ClickAPIClient, cache: CacheStore = .shared) {
        self.api = api
        self.cache = cache
    }

    // MARK: - Nearby discovery

    /// The last discovery on disk; its beacons also seed the detail cache, so events on Home
    /// and the Map open instantly right after launch.
    public func cachedDiscovery(userID: String) async -> NearbyDiscovery? {
        let stored = await cache.load(NearbyDiscovery.self, key: "nearby", userID: userID)
        if let stored { remember(stored.beacons) }
        return stored
    }

    /// Beacons (`GET /api/beacons`) and hubs (`GET /api/hub/nearby`) around a coordinate.
    /// Hubs are an enrichment: when that request fails the beacon result still stands.
    public func discovery(
        around coordinate: CLLocationCoordinate2D,
        radiusMeters: Int = BeaconRepository.discoveryRadiusMeters,
        userID: String,
        places: (any PlaceRepositoryProtocol)? = nil
    ) async throws -> NearbyDiscovery {
        async let beaconsTask = nearbyBeacons(around: coordinate, radiusMeters: radiusMeters, cursor: nil)
        async let hubsTask = nearbyHubs(around: coordinate, radiusMeters: radiusMeters)
        // Places are an enrichment: a failure leaves them empty and never fails discovery.
        async let placesTask: [PlaceSummary] = Self.nearbyPlaces(places, around: coordinate)
        let page = try await beaconsTask
        let hubs = (try? await hubsTask) ?? []
        let result = NearbyDiscovery(
            beacons: page.beacons,
            hubs: hubs,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            fetchedAt: .now,
            nextCursor: page.nextCursor,
            places: await placesTask
        )
        await cache.save(result, key: "nearby", userID: userID)
        remember(page.beacons)
        return result
    }

    /// The next page of beacons for `discovery`, merged in (nil when it has no more pages).
    public func moreBeacons(
        for discovery: NearbyDiscovery,
        radiusMeters: Int = BeaconRepository.discoveryRadiusMeters,
        userID: String
    ) async throws -> NearbyDiscovery? {
        guard let cursor = discovery.nextCursor else { return nil }
        let center = CLLocationCoordinate2D(latitude: discovery.latitude, longitude: discovery.longitude)
        let page = try await nearbyBeacons(around: center, radiusMeters: radiusMeters, cursor: cursor)
        let seen = Set(discovery.beacons.map(\.id))
        let result = NearbyDiscovery(
            beacons: discovery.beacons + page.beacons.filter { !seen.contains($0.id) },
            hubs: discovery.hubs,
            latitude: discovery.latitude,
            longitude: discovery.longitude,
            fetchedAt: discovery.fetchedAt,
            nextCursor: page.nextCursor,
            places: discovery.places
        )
        await cache.save(result, key: "nearby", userID: userID)
        remember(page.beacons)
        return result
    }

    /// Click Places radius for the map (the server clamps it; 5 km matches its default).
    public static let placesRadiusMeters = 5_000

    private static func nearbyPlaces(_ places: (any PlaceRepositoryProtocol)?, around coordinate: CLLocationCoordinate2D) async -> [PlaceSummary] {
        guard let places else { return [] }
        return (try? await places.nearby(around: coordinate, radiusMeters: placesRadiusMeters)) ?? []
    }

    /// One page of beacons, newest first; `nextCursor` is nil on the last page.
    public func nearbyBeacons(
        around coordinate: CLLocationCoordinate2D,
        radiusMeters: Int,
        cursor: String?
    ) async throws -> (beacons: [MapBeacon], nextCursor: String?) {
        var query = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "radius_meters", value: String(radiusMeters)),
            URLQueryItem(name: "limit", value: String(Self.discoveryPageSize))
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons", method: .get, queryItems: query))
        let root = try JSONFields.object(data)
        let next = JSONFields.string(root["next_cursor"]).flatMap { $0.isEmpty ? nil : $0 }
        return (JSONFields.rows(root["beacons"]).compactMap(MapBeacon.decode), next)
    }

    public func nearbyHubs(around coordinate: CLLocationCoordinate2D, radiusMeters: Int) async throws -> [NearbyHub] {
        let request = APIRequest(
            path: "/api/hub/nearby",
            method: .get,
            queryItems: [
                URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                URLQueryItem(name: "lon", value: String(coordinate.longitude)),
                URLQueryItem(name: "radius_meters", value: String(radiusMeters)),
                // The route's maximum; its default (50) would truncate a 50 km area.
                URLQueryItem(name: "limit", value: "100")
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
        known[id] = KnownBeacon(beacon: beacon, isExpired: expired, storedAt: .now)
        return (beacon, expired)
    }

    // MARK: - Beacon cache (instant detail)

    /// A cached beacon and whether it is still inside its freshness window.
    public nonisolated func cachedBeacon(id: String, now: Date = .now) -> (beacon: MapBeacon, isExpired: Bool, isFresh: Bool)? {
        guard let entry = known[id] else { return nil }
        return (entry.beacon, entry.isExpired, now.timeIntervalSince(entry.storedAt) < CachePolicy.beaconDetail)
    }

    /// Seeds the cache from list results without overwriting fresher detail reads.
    public func remember(_ beacons: [MapBeacon]) {
        let now = Date()
        for beacon in beacons where known[beacon.id] == nil {
            known[beacon.id] = KnownBeacon(beacon: beacon, isExpired: false, storedAt: now)
        }
        known.trim(to: 300, by: \.storedAt)
    }

    /// The beacon's banner image (`metadata.image_url`), from the detail cache when present
    /// (stale is fine for a picture), else one detail read. Nil when it has none.
    public func imageURL(beaconID: String) async -> String? {
        if let cached = cachedBeacon(id: beaconID) { return cached.beacon.imageURL }
        return try? await beacon(id: beaconID).beacon.imageURL
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
            known[id] = KnownBeacon(beacon: beacon, isExpired: false, storedAt: .now)
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
