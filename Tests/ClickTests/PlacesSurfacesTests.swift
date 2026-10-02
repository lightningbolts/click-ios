import Foundation
import Testing
@testable import Click

@Suite("Click Places surfaces: privacy setting, event link, reconnect card")
struct PlacesSurfacesTests {
    @Test("LocationPrivacy carries the Place visits key, written only with Places on")
    func locationPrivacyRow() throws {
        let privacy = LocationPrivacy(connectionSnap: true, memoryMap: false, businessInsights: false, placeVisitsVisible: true)
        #expect(privacy.row["place_visits_visible_to_connections"] == true)
        #expect(privacy.writeRow(includingPlaceVisits: true)["place_visits_visible_to_connections"] == true)
        #expect(privacy.writeRow(includingPlaceVisits: false)["place_visits_visible_to_connections"] == nil)
        #expect(LocationPrivacy.keys(includingPlaceVisits: false).count == 3)
        #expect(LocationPrivacy.keys(includingPlaceVisits: true).contains(.placeVisitsVisible))
        // Absent means off; older saved values still decode.
        #expect(LocationPrivacy(row: [:]).placeVisitsVisible == false)
        let old = Data(#"{"connectionSnap":true,"memoryMap":false,"businessInsights":true}"#.utf8)
        let decoded = try JSONDecoder().decode(LocationPrivacy.self, from: old)
        #expect(decoded.placeVisitsVisible == false)
        #expect(decoded.businessInsights == true)
    }

    @Test("Event detail shows \"At {place}\" only with Places on")
    func eventPlaceLink() throws {
        let row: [String: Any] = [
            "id": "e1", "beacon_type": "event", "creator_id": "u1", "lat": 47.6, "lng": -122.3,
            "venue_id": "p1",
            "place": ["id": "p1", "slug": "cafe-allegro-seattle", "name": "Café Allegro"]
        ]
        let beacon = try #require(MapBeacon.decode(row))
        #expect(beacon.venueID == "p1")
        #expect(BeaconDetailView.placeLink(for: beacon, placesEnabled: true)?.name == "Café Allegro")
        #expect(BeaconDetailView.placeLink(for: beacon, placesEnabled: false) == nil)

        let unlisted = try #require(MapBeacon.decode(["id": "e2", "beacon_type": "event", "creator_id": "u1", "lat": 47.6, "lng": -122.3, "venue_id": "p2"] as [String: Any]))
        #expect(BeaconDetailView.placeLink(for: unlisted, placesEnabled: true) == nil)
    }

    @Test("The reconnect nudge carries the Place when the meeting was at one")
    func reconnectPlace() throws {
        let root: [String: Any] = [
            "nudge": [
                "id": "n1", "connection_id": "c1", "user": ["id": "u2", "name": "Maya"],
                "met_at": "2026-06-01T20:00:00Z", "place_name": "Café Allegro",
                "place_id": "p1", "place_slug": "cafe-allegro-seattle", "title": "t", "body": "b"
            ] as [String: Any]
        ]
        let nudge = try #require(ReconnectNearbyNudge.parse(root))
        #expect(nudge.placeID == "p1")
        #expect(nudge.placeSlug == "cafe-allegro-seattle")
    }

    @Test("My Places rows read \"4 visits · Last …\"")
    func myPlacesLine() throws {
        let visit = MyPlaceVisit(place: PlacesMapTests.place("p1"), checkInCount: 4, lastCheckInAt: nil, encounterCount: 2)
        #expect(MyPlacesView.visitsLine(visit) == "4 visits")
        let once = MyPlaceVisit(place: PlacesMapTests.place("p1"), checkInCount: 1, lastCheckInAt: nil, encounterCount: 0)
        #expect(MyPlacesView.visitsLine(once) == "1 visit")
    }
}
