import Testing
import Foundation
@testable import Click

@Suite("Card visual parity with click-web generateCardVisual")
struct CardVisualTests {
    // Golden values produced by running click-web `lib/ui/generateCardVisual.ts` in Node.
    @Test("Matches web golden fixtures")
    func goldenFixtures() {
        let cases: [(String, Int32, [String], CardVisual.Pattern, CardVisual.HueFamily, Double)] = [
            ("click", 1551804527, ["#15803D", "#115E59"], .diagonals, .green, 0.28),
            ("8f14e45f-ceea-467a-9575-7d7a9f2a1c11", -1182017743, ["#4C1D95", "#5A00C6", "#4ADE80"], .chevron, .purple, 0.4),
            ("b1946ac9-2492-4f1b-a3e4-1b0c7e0f6e42", -1305433262, ["#630ED4", "#D2BBFF", "#F59E0B"], .dots, .purple, 0.42),
            ("e4da3b7f-bbce-4345-bb2b-df2c0e0b9f3a", 2119297062, ["#224CFF", "#6B8CFF", "#5A00C6"], .grid, .blue, 0.28)
        ]
        for (seed, hash, gradient, pattern, hue, scrim) in cases {
            let visual = CardVisual(seed: seed)
            #expect(visual.hash == UInt32(bitPattern: hash), "hash for \(seed)")
            #expect(visual.gradient == gradient, "gradient for \(seed)")
            #expect(visual.pattern == pattern, "pattern for \(seed)")
            #expect(visual.hueFamily == hue, "hue for \(seed)")
            #expect(visual.scrimAlpha == scrim, "scrim for \(seed)")
        }
    }

    @Test("Empty seed falls back to the web default seed")
    func emptySeed() {
        #expect(CardVisual(seed: "") == CardVisual(seed: "click"))
    }
}

@Suite("Beacon taxonomy reconciliation")
struct BeaconKindTests {
    @Test("Maps stored backend beacon_type values to canonical mobile kinds")
    func storedValues() {
        #expect(BeaconKind(raw: "recreation") == .socialVibe)
        #expect(BeaconKind(raw: "hobby") == .other)
        #expect(BeaconKind(raw: "hazard_utility") == .hazard)
        #expect(BeaconKind(raw: "transit") == .other)
        #expect(BeaconKind(raw: "swag") == .other)
        #expect(BeaconKind(raw: "social_vibe") == .socialVibe)
        #expect(BeaconKind(raw: "EVENT") == .event)
        #expect(BeaconKind(raw: "music") == .soundtrack)
        #expect(BeaconKind(raw: nil) == .other)
    }

    @Test("Layers group kinds exactly like click-web mapLayerForBeacon")
    func layers() {
        #expect(MapLayer(kind: .event) == .events)
        #expect(MapLayer(kind: .socialVibe) == .social)
        #expect(MapLayer(kind: .soundtrack) == .soundtracks)
        for kind in [BeaconKind.hazard, .utility, .sos, .study] {
            #expect(MapLayer(kind: kind) == .alerts)
        }
        #expect(MapLayer(kind: .other) == .other)
    }

    @Test("Decodes a beacon row defensively, including legacy metadata keys")
    func decodeBeacon() {
        let row: [String: Any] = [
            "id": "b1", "beacon_type": "event", "creator_id": "u1", "lat": 47.6, "lng": -122.3,
            "show_creator_name": true, "creator_name": "Maya",
            "created_at": "2026-09-20 18:00:00+00", "expires_at": "2026-09-30T00:00:00Z",
            "metadata": "{\"title\":\"Hack Night\",\"eventStartAt\":\"2026-09-26T02:00:00.000Z\",\"event_end_at\":\"2026-09-26T05:00:00Z\",\"place_name\":\"Allen Center\",\"event_categories\":[\"Tech\",{\"label\":\"Social\"},\"tech\"]}"
        ]
        let beacon = MapBeacon.decode(row)
        #expect(beacon?.title == "Hack Night")
        #expect(beacon?.locationName == "Allen Center")
        #expect(beacon?.schedule != nil)
        #expect(beacon?.eventCategories == ["Tech", "Social"])
        #expect(beacon?.visibleCreatorName == "Maya")
        #expect(beacon?.createdAt != nil)
        #expect(MapBeacon.decode(["id": "no-coords"]) == nil)
    }

    @Test("A deleted bookmarked event is unavailable, not a live saved event")
    func unavailableBookmark() {
        let row: [String: Any] = ["beacon_id": "gone", "title": "Unavailable event", "created_at": NSNull()]
        let saved = SavedEvent.decode(row)
        #expect(saved?.isAvailable == false)
        #expect(saved?.title == nil)
        #expect(saved?.isUpcomingOrLive() == false)
    }
}

@Suite("Server timestamp parsing")
struct ClickDateParserTests {
    @Test("Parses ISO, fractional ISO, Postgres text, and epoch forms")
    func forms() {
        let expected = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(JSONFields.date("2026-09-21T14:13:20Z") == expected)
        #expect(JSONFields.date("2026-09-21T14:13:20.000Z") == expected)
        #expect(JSONFields.date("2026-09-21 14:13:20+00") == expected)
        #expect(JSONFields.date(1_790_000_000_000 as NSNumber) == expected)
        #expect(JSONFields.date("1790000000") == expected)
        #expect(JSONFields.date("not a date") == nil)
        #expect(JSONFields.date(true) == nil)
    }
}

@Suite("Module load states")
struct ModuleStateTests {
    @Test("A failed refresh keeps cached data as stale instead of emptying it")
    func staleOnFailure() {
        var state = ModuleState<[String]>()
        #expect(state.isPending)
        state.seed(["cached"])
        state.begin()
        state.fail("offline")
        #expect(state.value == ["cached"])
        #expect(state.isStale)
        #expect(!state.isFresh)
    }

    @Test("A failure with no cache has no value to render as empty")
    func failureWithoutCache() {
        var state = ModuleState<ActivityRecap>()
        state.begin()
        state.fail("server")
        #expect(state.value == nil)
        #expect(state.errorMessage == "server")
        #expect(!state.isPending)
    }

    @Test("Recap decode requires the recap object; zeros only come from the server")
    func recapDecode() throws {
        #expect(throws: APIError.self) {
            _ = try ActivityRecap.decode(["error": "Failed"], window: .week)
        }
        let empty = try ActivityRecap.decode(["recap": ["connections_formed": 0]], window: .day)
        #expect(empty.isEmpty)
        let active = try ActivityRecap.decode(["recap": ["messages_sent": "4"]], window: .week)
        #expect(!active.isEmpty)
        #expect(active.messagesSent == 4)
    }
}

@Suite("Home opportunity priority")
struct HomeOpportunityTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func saved(_ id: String, startOffset: TimeInterval, duration: TimeInterval = 3600) -> SavedEvent {
        SavedEvent(
            beaconID: id, title: id,
            schedule: EventSchedule(start: now.addingTimeInterval(startOffset), end: now.addingTimeInterval(startOffset + duration)),
            locationName: nil, formattedAddress: nil, categories: [], latitude: nil, longitude: nil,
            expiresAt: nil, creatorName: nil, bookmarkedAt: nil, isAvailable: true
        )
    }

    private func nudge(_ id: String, kind: InboxNudge.Kind) -> InboxNudge {
        InboxNudge(id: id, kind: kind, connectionID: "c1", beaconID: nil, headline: "h", body: "b", peerFirstName: nil, sentAt: nil)
    }

    @Test("A live saved event outranks nudges and later saved events")
    func liveSavedFirst() {
        let result = HomeOpportunity.select(
            savedEvents: [saved("later", startOffset: 3600), saved("live", startOffset: -600)],
            nearbyBeacons: [],
            nudges: [nudge("n", kind: .sharedUpcomingEvent)],
            connections: [],
            now: now
        )
        #expect(result?.id == "event.live")
    }

    @Test("Shared-event nudge outranks reconnect nudge when no saved event is today")
    func nudgeOrder() {
        let result = HomeOpportunity.select(
            savedEvents: [saved("next-week", startOffset: 7 * 86_400)],
            nearbyBeacons: [],
            nudges: [nudge("r", kind: .reconnectLull), nudge("s", kind: .sharedUpcomingEvent)],
            connections: [],
            now: now
        )
        #expect(result?.id == "nudge.s")
    }

    @Test("Ended events, unavailable bookmarks, and nothing else yield no opportunity")
    func nothing() {
        var gone = saved("ended", startOffset: -7200)
        gone = SavedEvent(beaconID: gone.beaconID, title: gone.title, schedule: gone.schedule, locationName: nil,
                          formattedAddress: nil, categories: [], latitude: nil, longitude: nil, expiresAt: nil,
                          creatorName: nil, bookmarkedAt: nil, isAvailable: true)
        let result = HomeOpportunity.select(savedEvents: [gone], nearbyBeacons: [], nudges: [], connections: [], now: now)
        #expect(result == nil)
    }
}

@Suite("Map connection pins")
struct MapPinTests {
    @Test("One pin per peer at the first-meet location; reconnects never move or duplicate it")
    func firstMeetPin() {
        let rows: [[String: Any]] = [
            ["id": "c-new", "user_ids": ["me", "peer"], "created": 1_790_000_000_000,
             "connection_encounters": [["encountered_at": "2026-09-22T19:00:00Z", "gps_lat": 10.0, "gps_lon": 10.0]]],
            ["id": "c-old", "user_ids": ["me", "peer"], "created": 1_700_000_000_000,
             "connection_encounters": [
                ["encountered_at": "2026-09-22T19:00:00Z", "gps_lat": 47.62, "gps_lon": -122.35],
                ["encountered_at": "2024-01-01T10:00:00Z", "gps_lat": 47.60, "gps_lon": -122.33, "location_name": "Café"]
             ]],
            ["id": "c-nogps", "user_ids": ["me", "other"], "geo_location": ["lat": 0, "lon": 0]]
        ]
        let pins = Phase3Repository.mapPins(rows: rows, currentUserID: "me", identities: [:], coreIDs: ["c-old"])
        #expect(pins.count == 1)
        #expect(pins.first?.connectionID == "c-old")
        #expect(pins.first?.latitude == 47.60)
        #expect(pins.first?.locationName == "Café")
        #expect(pins.first?.isCore == true)
    }

    @Test("Stored geo_location wins over encounter GPS")
    func geoLocationFirst() {
        let row: [String: Any] = ["geo_location": ["lat": 1.5, "lon": 2.5],
                                  "connection_encounters": [["gps_lat": 9.0, "gps_lon": 9.0]]]
        let coordinate = Phase3Repository.pinCoordinate(row)
        #expect(coordinate?.latitude == 1.5)
        #expect(coordinate?.longitude == 2.5)
    }
}

@Suite("Availability overlaps")
struct AvailabilityOverlapTests {
    @Test("Only peers flagged has_overlap are kept")
    func parse() {
        let data = Data(#"[{"peer_id":"a","has_overlap":true},{"peer_id":"b","has_overlap":false},{"peer_id":"c"}]"#.utf8)
        #expect(MeRepository.overlappingPeers(data) == ["a"])
        #expect(MeRepository.overlappingPeers(Data("oops".utf8)).isEmpty)
    }

    @Test("Card title by count")
    func title() {
        #expect(HomeFeedModel.overlapTitle(names: []) == nil)
        #expect(HomeFeedModel.overlapTitle(names: ["Lena"]) == "Lena is also free")
        #expect(HomeFeedModel.overlapTitle(names: ["Lena", "Sam"]) == "Lena and Sam are also free")
        #expect(HomeFeedModel.overlapTitle(names: ["A", "B", "C"]) == "3 Clicks are also free")
    }
}
