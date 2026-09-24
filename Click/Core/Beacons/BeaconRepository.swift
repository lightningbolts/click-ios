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
        return (beacon, JSONFields.bool(root["expired"]) ?? false)
    }
}
