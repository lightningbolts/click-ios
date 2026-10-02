import CoreLocation
import Foundation
import Testing
@testable import Click

private final class FixtureBundleToken {}

@Suite("Place filters (shared fixture with click-web)")
struct PlaceFilterTests {
    struct Fixture {
        let places: [PlaceSummary]
        let cases: [(name: String, filters: PlaceFilters, expected: [String])]
    }

    static func loadFixture() throws -> Fixture {
        let bundle = Bundle(for: FixtureBundleToken.self)
        let url = try #require(bundle.url(forResource: "place_filters", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let places = JSONFields.rows(root["places"]).compactMap(PlaceSummary.decode)
        let cases = JSONFields.rows(root["cases"]).map { row -> (String, PlaceFilters, [String]) in
            let f = JSONFields.dictionary(row["filters"]) ?? [:]
            var filters = PlaceFilters()
            filters.categories = Set(JSONFields.stringArray(f["categories"]).compactMap(PlaceCategory.init(rawValue:)))
            filters.pulseNow = JSONFields.bool(f["pulseNow"]) ?? false
            filters.minReports = JSONFields.int(f["minReports"]) ?? 0
            filters.energies = Set(JSONFields.stringArray(f["energies"]).compactMap(EnergyLabel.init(rawValue:)))
            filters.eventsToday = JSONFields.bool(f["eventsToday"]) ?? false
            filters.openNow = JSONFields.bool(f["openNow"]) ?? false
            filters.beenHere = JSONFields.bool(f["beenHere"]) ?? false
            filters.clicksBeenHere = JSONFields.bool(f["clicksBeenHere"]) ?? false
            filters.hasHub = JSONFields.bool(f["hasHub"]) ?? false
            filters.hereNow = JSONFields.bool(f["hereNow"]) ?? false
            return (JSONFields.string(row["name"]) ?? "", filters, JSONFields.stringArray(row["expected_ids"]))
        }
        return Fixture(places: places, cases: cases)
    }

    @Test("Every fixture case matches the web semantics")
    func fixtureCases() throws {
        let fixture = try Self.loadFixture()
        #expect(fixture.places.count == 5)
        #expect(!fixture.cases.isEmpty)
        for testCase in fixture.cases {
            let ids = testCase.filters.apply(fixture.places).map(\.id)
            #expect(ids == testCase.expected, "\(testCase.name)")
        }
    }

    @Test("No filters is inactive and shows everything")
    func noFilters() throws {
        let fixture = try Self.loadFixture()
        #expect(!PlaceFilters.none.isActive)
        #expect(PlaceFilters.none.apply(fixture.places).count == fixture.places.count)
    }

    @Test("Filters persist, and a corrupt value falls back to none")
    func persistence() throws {
        let defaults = try #require(UserDefaults(suiteName: "place-filters-tests"))
        defaults.removePersistentDomain(forName: "place-filters-tests")
        var filters = PlaceFilters()
        filters.pulseNow = true
        filters.categories = [.bar]
        filters.save(to: defaults)
        #expect(PlaceFilters.load(from: defaults) == filters)
        defaults.set(Data("not json".utf8), forKey: PlaceFilters.storageKey)
        #expect(PlaceFilters.load(from: defaults) == .none)
    }
}

@Suite("Places on the map")
struct PlacesMapTests {
    static func place(_ id: String, lat: Double = 47.6588) -> PlaceSummary {
        PlaceSummary(
            id: id, slug: id, name: id, category: .cafe, photoURL: nil, latitude: lat, longitude: -122.3131,
            radiusMeters: 75, distanceMeters: 100, addressLine: nil, city: nil, openNow: nil, pulse: .empty,
            hereNowCount: 0, eventsTodayCount: 1, nextEvent: nil, hubID: nil, viewer: nil
        )
    }

    static func event(_ id: String, venueID: String?) throws -> MapBeacon {
        var row: [String: Any] = [
            "id": id, "beacon_type": "event", "creator_id": "u1", "lat": 47.6588, "lng": -122.3131,
            "metadata": ["title": "Open mic", "event_start_at": "2026-01-01T00:00:00Z", "event_end_at": "2099-01-01T00:00:00Z"],
            "expires_at": "2099-01-01T00:00:00Z"
        ]
        if let venueID { row["venue_id"] = venueID }
        return try #require(MapBeacon.decode(row))
    }

    static func discovery(beacons: [MapBeacon], places: [PlaceSummary]) -> NearbyDiscovery {
        NearbyDiscovery(beacons: beacons, hubs: [], latitude: 47.6, longitude: -122.3, fetchedAt: .now, places: places)
    }

    @Test("An official event at a listed Place merges into the Place pin")
    func eventMerge() throws {
        let d = Self.discovery(beacons: [try Self.event("e-at-place", venueID: "p1"), try Self.event("e-elsewhere", venueID: nil)], places: [Self.place("p1")])
        let ids = MapFeatureModel.items(discovery: d, placesEnabled: true).map(\.id)
        #expect(ids.contains(.place("p1")))
        #expect(ids.contains(.beacon("e-elsewhere")))
        #expect(!ids.contains(.beacon("e-at-place")))
    }

    @Test("With Places off, nothing changes: no Place pins and no merge")
    func flagOff() throws {
        let d = Self.discovery(beacons: [try Self.event("e-at-place", venueID: "p1")], places: [Self.place("p1")])
        let ids = MapFeatureModel.items(discovery: d, placesEnabled: false).map(\.id)
        #expect(ids == [.beacon("e-at-place")])
    }

    @Test("The Places layer toggle hides Place items")
    func layerToggle() {
        let d = Self.discovery(beacons: [], places: [Self.place("p1")])
        var layers = Set(MapLayer.allCases)
        #expect(MapFeatureModel.items(discovery: d, placesEnabled: true, layers: layers).count == 1)
        layers.remove(.places)
        #expect(MapFeatureModel.items(discovery: d, placesEnabled: true, layers: layers).isEmpty)
    }

    @Test("Place items route to the Place page and sit on the Places layer")
    func placeItem() {
        let item = MapItem(kind: .place(Self.place("p1")))
        #expect(item.layer == .places)
        #expect(item.route == .place(idOrSlug: "p1", anchorToken: nil))
        #expect(item.id == .place("p1"))
    }
}
