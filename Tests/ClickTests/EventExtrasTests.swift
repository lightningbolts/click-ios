import Foundation
import Testing
@testable import Click

@Suite("Events: Click Pass, Live Activity, weather, Place hosts")
struct EventExtrasTests {
    @Test("click://pass/{id} opens the Click Pass on the Map tab; the pass's web link opens the event")
    @MainActor
    func passRoutes() {
        let router = AppRouter()
        #expect(router.parseIncomingURL(URL(string: "click://pass/e1")!) == .eventPass(beaconID: "e1"))
        #expect(AppRoute.eventPass(beaconID: "e1").canonicalTab == .map)
        #expect(AppRoute.passScanner(beaconID: "e1").presentsAsSheet == false)
        // A Click Pass QR read by the system camera is the event's public link.
        #expect(router.parseIncomingURL(URL(string: "https://joinclick.co/e/e1?pass=1.abc.def")!) == .event(beaconID: "e1"))
    }

    @Test("The Live Activity covers events starting within three hours or on now, soonest first")
    func liveActivityWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, startsIn: TimeInterval, lasts: TimeInterval = 7200) -> MyEvent {
            MyEvent(beaconID: id, title: id, start: now.addingTimeInterval(startsIn),
                    end: now.addingTimeInterval(startsIn + lasts), place: nil, isHost: false)
        }
        let picked = EventLiveActivities.upcoming([
            event("later", startsIn: 4 * 3600),
            event("soon", startsIn: 2 * 3600),
            event("on", startsIn: -1800),
            event("over", startsIn: -3 * 3600, lasts: 3600),
        ], now: now)
        #expect(picked.map(\.beaconID) == ["on", "soon"])
    }

    @Test("Weather reads now first, then the start-time forecast with a rain chance worth mentioning")
    func weatherSummary() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let now = PlaceWeather.Reading(temperatureCelsius: 18, condition: "Cloudy", icon: "cloudy", isDay: true, precipitationChance: nil)
        let later = PlaceWeather.Reading(temperatureCelsius: 12, condition: "Rain", icon: "rain", isDay: false, precipitationChance: 70)
        let summary = PlaceWeather(now: now, atStart: later).summary(start: start) ?? ""
        #expect(summary.contains("Cloudy now"))
        #expect(summary.contains("Rain at"))
        #expect(summary.contains("70% chance of rain"))
        #expect(PlaceWeather(now: now, atStart: nil).summary(start: start)?.contains("at") == false)
        #expect(PlaceWeather(now: nil, atStart: nil).summary(start: nil) == nil)
        #expect(later.systemImage == "cloud.rain.fill")
        #expect(PlaceWeather.Reading(temperatureCelsius: 1, condition: "Clear", icon: "clear", isDay: false, precipitationChance: nil)
            .systemImage == "moon.stars.fill")
    }

    @Test("A Place hosting an event carries its photo and city; its events carry their pictures")
    func placeHostFields() throws {
        let beacon = try #require(MapBeacon.decode([
            "id": "e1", "beacon_type": "event", "creator_id": "u1", "lat": 47.6, "lng": -122.3, "venue_id": "p1",
            "place": ["id": "p1", "slug": "cafe", "name": "Café Allegro", "photo_url": "https://img/p1.jpg", "city": "Seattle"],
        ] as [String: Any]))
        #expect(beacon.place?.photoURL == "https://img/p1.jpg")
        #expect(beacon.place?.city == "Seattle")
        let ref = try #require(PlaceEventRef.decode(["beacon_id": "e1", "title": "Open mic", "image_url": "https://img/e1.jpg"]))
        #expect(ref.imageURL == "https://img/e1.jpg")
    }

    @Test("The forecast is for the start only while it's ahead")
    func forecastStart() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func beacon(startsIn: TimeInterval) throws -> MapBeacon {
            try #require(MapBeacon.decode([
                "id": "e1", "beacon_type": "event", "creator_id": "u1", "lat": 47.6, "lng": -122.3,
                "metadata": [
                    "event_start_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(startsIn)),
                    "event_end_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(startsIn + 3600)),
                ],
            ] as [String: Any]))
        }
        #expect(BeaconDetailView.forecastStart(try beacon(startsIn: 7200), now: now) != nil)
        #expect(BeaconDetailView.forecastStart(try beacon(startsIn: -600), now: now) == nil)
    }
}
