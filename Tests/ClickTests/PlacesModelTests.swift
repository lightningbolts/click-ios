import CoreLocation
import Foundation
import Testing
@testable import Click

@Suite("Click Places models, deep links and discovery cache")
struct PlacesModelTests {
    static let fullSummaryJSON = """
    {
      "id": "6a1f0000-0000-4000-8000-000000000001",
      "slug": "cafe-allegro-seattle",
      "name": "Café Allegro",
      "category": "cafe",
      "photo_url": "https://example.supabase.co/storage/v1/object/public/place-photos/6a1f/cover.jpg",
      "latitude": 47.6588, "longitude": -122.3131,
      "radius_meters": 75,
      "distance_meters": 412.3,
      "address_line": "4214 University Way NE",
      "city": "Seattle",
      "open_now": true,
      "pulse": {
        "state": "live", "label": "lively", "energy_score": 3.0, "report_count": 1,
        "newest_at": "2026-10-01T19:56:00.000Z", "confidence": "low",
        "distribution": [0, 0, 1, 0], "talkable": {"yes": 1, "no": 0},
        "category": {"question": "seats", "counts": [0, 1, 0]}, "window_minutes": 90
      },
      "here_now_count": 3,
      "events_today_count": 1,
      "next_event": {"beacon_id": "e1", "title": "Open mic", "starts_at": "2026-10-02T03:00:00Z", "ends_at": "2026-10-02T05:00:00Z", "is_live": false},
      "hub_id": "place-6a1f",
      "viewer": {"checked_in": false, "has_history": true, "connections_been_here_count": 2}
    }
    """

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    static var fullSummary: [String: Any] { object(fullSummaryJSON) }

    @Test("A full PlaceSummary decodes every field")
    func decodesFullSummary() throws {
        let place = try #require(PlaceSummary.decode(Self.fullSummary))
        #expect(place.slug == "cafe-allegro-seattle")
        #expect(place.category == .cafe)
        #expect(place.category.symbol == "cup.and.saucer.fill")
        #expect(place.openNow == true)
        #expect(place.pulse.state == .live)
        #expect(place.pulse.label == .lively)
        #expect(place.pulse.reportCount == 1)
        #expect(place.pulse.confidence == .low)
        #expect(place.pulse.distribution == [0, 0, 1, 0])
        #expect(place.pulse.categoryCounts == [0, 1, 0])
        #expect(place.nextEvent?.title == "Open mic")
        #expect(place.viewer?.connectionsBeenHereCount == 2)
        #expect(place.hubID == "place-6a1f")
    }

    @Test("A minimal PlaceSummary decodes; unknown category falls back to Place")
    func minimalSummary() throws {
        let place = try #require(PlaceSummary.decode(Self.object(#"{"id": "p1", "latitude": 1.5, "longitude": 2.5, "category": "church"}"#)))
        #expect(place.category == .other)
        #expect(place.category.label == "Place")
        #expect(place.pulse == .empty)
        #expect(place.viewer == nil)
        #expect(place.openNow == nil)
        #expect(PlaceSummary.decode(["id": "no-coordinates"]) == nil)
    }

    @Test("PlaceDetail decodes viewer sections and Pulse eligibility")
    func detail() throws {
        var row = Self.fullSummary
        let extra = Self.object("""
        {
          "directions": {"apple_maps_url": "https://maps.apple.com/?daddr=47.6588,-122.3131", "google_maps_url": "https://www.google.com/maps/dir/?api=1&destination=47.6588,-122.3131"},
          "pattern": {"label": "lively", "report_count": 6, "weeks": 8},
          "clicks_been_here": {"count": 2, "names": ["Jordan", "Maya"]},
          "you_met_here": {"total": 1, "people": [{"user_id": "u1", "name": "Maya", "avatar_url": null, "last_met_at": "2026-09-28T20:00:00Z"}]},
          "own_history": {"check_in_count": 4, "last_check_in_at": "2026-09-28T20:00:00Z", "encounter_count": 2},
          "check_in": {"active": true, "check_in_id": "ci1", "checked_in_at": "2026-10-01T19:00:00Z", "expires_at": "2026-10-01T22:00:00Z", "proof": "qr", "share_with_connections": true},
          "pulse_eligibility": {
            "can_pulse": false, "reason": "cooldown", "cooldown_until": "2026-10-01T20:40:00Z",
            "questions": [{"key": "energy", "prompt": "How's the energy?", "required": true, "phase": "present", "options": [{"value": 1, "label": "Chill"}]}],
            "leaving_questions": [{"key": "would_return", "prompt": "Come back at this time?", "required": false, "phase": "leaving", "options": [{"value": 1, "label": "Yes"}, {"value": 0, "label": "No"}]}],
            "my_last_pulse": null
          },
          "hub": {"id": "place-6a1f", "name": "Café Allegro", "joined": false},
          "is_manager": false
        }
        """)
        row.merge(extra) { _, new in new }

        let detail = try #require(PlaceDetail.decode(row))
        #expect(detail.pattern == PlacePattern(label: .lively, reportCount: 6, weeks: 8))
        #expect(detail.clicksBeenHere == ClicksBeenHere(count: 2, names: ["Jordan", "Maya"]))
        #expect(detail.youMetHere?.people.first?.name == "Maya")
        #expect(detail.ownHistory?.checkInCount == 4)
        #expect(detail.checkIn?.proof == "qr")
        #expect(detail.pulseEligibility?.reason == .cooldown)
        #expect(detail.pulseEligibility?.questions.first?.options.first?.label == "Chill")
        #expect(detail.pulseEligibility?.leavingQuestions.first?.key == "would_return")
        #expect(detail.hub?.joined == false)
        #expect(detail.appleMapsURL != nil)
    }

    @Test("Validation bodies map to PlaceError codes")
    func errors() {
        #expect(PlaceError.fromValidation(#"{"error":"x","code":"out_of_bounds","distance_meters":300}"#) == .outOfBounds(distance: 300))
        #expect(PlaceError.fromValidation(#"{"code":"low_accuracy"}"#) == .lowAccuracy)
        #expect(PlaceError.fromValidation(#"{"code":"invalid_anchor"}"#) == .invalidAnchor)
        #expect(PlaceError.fromValidation("not json") == nil)
        #expect(PlaceError.map(APIError.notFound, forbidden: .notPresent) as? PlaceError == .notFound)
        #expect(PlaceError.map(APIError.forbidden, forbidden: .managerPulseNotAllowed) as? PlaceError == .managerPulseNotAllowed)
    }
}

@Suite("Click Places deep links")
@MainActor
struct PlaceDeepLinkTests {
    let router = AppRouter()

    @Test("click://p/{slug} with and without a check-in token")
    func customScheme() {
        #expect(router.parseIncomingURL(URL(string: "click://p/cafe-allegro-seattle")!) == .place(idOrSlug: "cafe-allegro-seattle", anchorToken: nil))
        #expect(router.parseIncomingURL(URL(string: "click://p/cafe-allegro-seattle?t=tok123")!) == .place(idOrSlug: "cafe-allegro-seattle", anchorToken: "tok123"))
        #expect(router.parseIncomingURL(URL(string: "click://p/studio-54-nyc-2?t=")!) == .place(idOrSlug: "studio-54-nyc-2", anchorToken: nil))
    }

    @Test("https://joinclick.co/p/{slug} universal links")
    func universalLinks() {
        #expect(router.parseIncomingURL(URL(string: "https://joinclick.co/p/cafe-allegro-seattle")!) == .place(idOrSlug: "cafe-allegro-seattle", anchorToken: nil))
        #expect(router.parseIncomingURL(URL(string: "https://joinclick.co/p/back-bar-2?t=f0000000-0000-4000-8000-000000000001")!)
            == .place(idOrSlug: "back-bar-2", anchorToken: "f0000000-0000-4000-8000-000000000001"))
        #expect(router.parseIncomingURL(URL(string: "https://joinclick.co/p")!) == nil)
    }

    @Test("Places open on the Map tab")
    func canonicalTab() {
        #expect(AppRoute.place(idOrSlug: "x", anchorToken: nil).canonicalTab == .map)
    }
}

@Suite("Nearby discovery cache with Places")
struct NearbyDiscoveryPlacesCacheTests {
    @Test("An old cached discovery without places still decodes")
    func oldCache() throws {
        let discovery = NearbyDiscovery(beacons: [], hubs: [], latitude: 47.6, longitude: -122.3, fetchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(discovery)) as? [String: Any])
        json.removeValue(forKey: "places")
        let decoded = try JSONDecoder().decode(NearbyDiscovery.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.places.isEmpty)
        #expect(decoded.latitude == 47.6)
    }

    @Test("Places survive the cache round trip")
    func roundTrip() throws {
        let place = try #require(PlaceSummary.decode(PlacesModelTests.fullSummary))
        let discovery = NearbyDiscovery(beacons: [], hubs: [], latitude: 1, longitude: 2, fetchedAt: .now, places: [place])
        let decoded = try JSONDecoder().decode(NearbyDiscovery.self, from: JSONEncoder().encode(discovery))
        #expect(decoded.places == [place])
    }
}
