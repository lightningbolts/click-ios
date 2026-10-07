import CoreLocation
import Testing
@testable import Click

@Suite("Nearby sheet and map clustering")
struct NearbyMapTests {

    private func pin(_ id: String, _ lat: Double, _ lon: Double) -> MapItem {
        MapItem(kind: .person(ConnectionPin(connectionID: id, userID: id, displayName: id, avatarURL: nil,
                                            latitude: lat, longitude: lon, locationName: nil, isCore: false)))
    }

    private func beacon(_ id: String, type: String, lat: Double, lon: Double, start: Date? = nil, end: Date? = nil) throws -> MapItem {
        var meta: [String: Any] = ["title": id]
        if let start, let end {
            meta["event_start_at"] = start.ISO8601Format()
            meta["event_end_at"] = end.ISO8601Format()
        }
        let row: [String: Any] = ["id": id, "lat": lat, "lng": lon, "beacon_type": type, "metadata": meta]
        return MapItem(kind: .beacon(try #require(MapBeacon.decode(row))))
    }

    @Test("Pins stack exactly when they would overlap on screen")
    func stacking() {
        // a and b ~600 m apart; c ~40 km away.
        let items = [pin("a", 47.6200, -122.3200), pin("b", 47.6250, -122.3240), pin("c", 47.9, -122.9)]
        // Zoom 16: ~1.6 m per point, so 600 m is ~370 pt apart. Nothing overlaps.
        #expect(MapFeatureModel.clusters(items, zoom: 16).count == 3)
        // Zoom 12: ~26 m per point, so a and b are ~23 pt apart and would overlap.
        let zoomedOut = MapFeatureModel.clusters(items, zoom: 12)
        #expect(zoomedOut.count == 2)
        #expect(zoomedOut.contains { $0.items.map(\.title).sorted() == ["a", "b"] })
        // Same spot (one venue): stacked even fully zoomed in.
        let venue = [pin("x", 47.62, -122.32), pin("y", 47.62001, -122.32001)]
        #expect(MapFeatureModel.clusters(venue, zoom: 20).count == 1)
    }

    @Test("A stack leads with what matters most (an alert first) and sits on its lead")
    func stackLead() throws {
        let now = Date()
        let person = pin("Ana", 47.62, -122.32)
        let later = try beacon("Later", type: "event", lat: 47.62001, lon: -122.32,
                               start: now.addingTimeInterval(3 * 86_400), end: now.addingTimeInterval(3 * 86_400 + 3_600))
        let live = try beacon("Live", type: "event", lat: 47.62002, lon: -122.32,
                              start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3_600))
        let hazard = try beacon("Hazard", type: "hazard", lat: 47.62, lon: -122.32001)
        let clusters = MapFeatureModel.clusters([person, later, hazard, live], zoom: 18, now: now)
        #expect(clusters.count == 1)
        let stack = try #require(clusters.first)
        #expect(stack.items.map(\.title) == ["Hazard", "Live", "Later", "Ana"])
        #expect(stack.coordinate.longitude == hazard.coordinate.longitude)
        let withoutAlert = MapFeatureModel.clusters([person, later, live], zoom: 18, now: now)
        #expect(withoutAlert.first?.items.map(\.title) == ["Live", "Later", "Ana"])
        #expect(withoutAlert.first?.coordinate.latitude == live.coordinate.latitude)
    }

    @Test("Zoom in is offered only when a stack's members can be drawn apart, and fits them all")
    func stackZoom() {
        let sameSpot = MapCluster(id: "s", coordinate: .init(latitude: 47.62, longitude: -122.32),
                                  items: [pin("a", 47.62, -122.32), pin("b", 47.62001, -122.32001)])
        #expect(!MapFeatureModel.canSeparate(sameSpot))
        let spread = MapCluster(id: "t", coordinate: .init(latitude: 47.62, longitude: -122.32),
                                items: [pin("a", 47.62, -122.32), pin("b", 47.63, -122.34)])
        #expect(MapFeatureModel.canSeparate(spread))
        let region = MapFeatureModel.region(fitting: spread)
        for item in spread.items {
            #expect(abs(item.coordinate.latitude - region.center.latitude) < region.span.latitudeDelta / 2)
            #expect(abs(item.coordinate.longitude - region.center.longitude) < region.span.longitudeDelta / 2)
        }
    }

    @Test("Nearby rows read for every beacon kind, not only events")
    @MainActor
    func beaconRows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func beacon(_ type: String, meta: [String: Any] = [:], created: TimeInterval? = nil, expires: TimeInterval? = nil) throws -> MapItem {
            var row: [String: Any] = ["id": type, "lat": 47.6, "lng": -122.3, "beacon_type": type, "metadata": meta]
            if let created { row["created_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(created)) }
            if let expires { row["expires_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(expires)) }
            return MapItem(kind: .beacon(try #require(MapBeacon.decode(row))))
        }

        let hazard = NearbyRow.eyebrow(try beacon("hazard", expires: 40 * 60), now: now)
        #expect(hazard.tone == .alert)
        #expect(hazard.text.hasPrefix("Hazard · ends "))
        #expect(NearbyRow.eyebrow(try beacon("sos", created: -600), now: now).tone == .live)
        let study = NearbyRow.eyebrow(try beacon("study", created: -2 * 3600, expires: 3 * 24 * 3600), now: now)
        #expect(study.tone == .plain)
        #expect(study.text.hasPrefix("Study · ") && study.text.contains("ago"))
        #expect(NearbyRow.eyebrow(try beacon("utility"), now: now).text == "Utility")

        // A soundtrack leads with its artist; a legacy "Current location" label shows the address.
        let song = try beacon("soundtrack", meta: ["artist_name": "Phoebe Bridgers", "location_name": "Suzzallo"])
        #expect(NearbyRow.place(song) == "Phoebe Bridgers · Suzzallo")
        let legacy = try beacon("hazard", meta: ["location_name": "Current location", "formatted_address": "4215 E Stevens Way NE"])
        #expect(NearbyRow.place(legacy) == "4215 E Stevens Way NE")
        #expect(NearbyRow.place(try beacon("other")) == nil)
    }

    private func event(_ id: String, going: Int, hoursOld: Double, lat: Double, now: Date) -> MapItem {
        let created = now.addingTimeInterval(-hoursOld * 3600).ISO8601Format()
        let row: [String: Any] = ["id": id, "lat": lat, "lng": -122.32, "beacon_type": "event", "created_at": created,
                                  "rsvp_count": going, "metadata": ["title": id]]
        return MapItem(kind: .beacon(MapBeacon.decode(row)!))
    }

    @Test("Events show their RSVP count; Nearby sorts by distance, A–Z, new and rising")
    func sorting() {
        let now = Date()
        let here = CLLocationCoordinate2D(latitude: 47.62, longitude: -122.32)
        // "Old" is busiest but a day old; "Fresh" is filling up fast; "Quiet" has no one yet.
        let items = [
            event("Old", going: 40, hoursOld: 24, lat: 47.63, now: now),
            event("Quiet", going: 0, hoursOld: 0.5, lat: 47.64, now: now),
            event("Fresh", going: 8, hoursOld: 1, lat: 47.65, now: now)
        ]
        #expect(items.map(\.peopleLabel) == ["40 going", nil, "8 going"])
        func order(_ sort: NearbySort, from origin: CLLocationCoordinate2D? = here) -> [String] {
            MapFeatureModel.sorted(items, by: sort, from: origin, now: now).map(\.title)
        }
        #expect(order(.relevance) == ["Old", "Quiet", "Fresh"])
        #expect(order(.distance) == ["Old", "Quiet", "Fresh"])
        #expect(order(.distance, from: nil) == ["Fresh", "Old", "Quiet"])
        #expect(order(.alphabetical) == ["Fresh", "Old", "Quiet"])
        #expect(order(.new) == ["Quiet", "Fresh", "Old"])
        #expect(order(.rising) == ["Fresh", "Old", "Quiet"])
    }
}
