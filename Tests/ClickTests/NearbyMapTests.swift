import CoreLocation
import Testing
@testable import Click

@Suite("Nearby sheet and map clustering")
struct NearbyMapTests {

    private func pin(_ id: String, _ lat: Double, _ lon: Double) -> MapItem {
        MapItem(kind: .person(ConnectionPin(connectionID: id, userID: id, displayName: id, avatarURL: nil,
                                            latitude: lat, longitude: lon, locationName: nil, isCore: false)))
    }

    @Test("Zoomed in, every pin stands alone; zoomed out, close pins merge")
    func clustering() {
        let items = [pin("a", 47.6200, -122.3200), pin("b", 47.6250, -122.3240), pin("c", 47.9, -122.9)]
        #expect(MapFeatureModel.clusters(items, zoom: 14).count == 3)
        // Zoom 9 → 1 km radius: a and b (~600 m apart) merge, c (~40 km away) doesn't.
        let zoomedOut = MapFeatureModel.clusters(items, zoom: 9)
        #expect(zoomedOut.count == 2)
        #expect(zoomedOut.contains { $0.items.count == 2 })
    }

    @Test("Pins at the same venue are offered in the chooser; distant ones are not")
    func overlap() {
        let a = pin("a", 47.6200, -122.3200)
        let b = pin("b", 47.62001, -122.32001)
        let c = pin("c", 47.6300, -122.3300)
        let stack = MapFeatureModel.overlapping(a, in: [a, b, c], zoom: 16)
        #expect(stack.map(\.title) == ["a", "b"])
    }

    @Test("Overlap radius follows KMP: 44 pt × 0.85 × metres per point, clamped 12–90 m")
    func overlapRadius() {
        #expect(MapFeatureModel.overlapRadiusMeters(latitude: 0, zoom: 22) == 12)
        #expect(MapFeatureModel.overlapRadiusMeters(latitude: 0, zoom: 10) == 90)
        let mid = MapFeatureModel.overlapRadiusMeters(latitude: 0, zoom: 16)
        #expect(abs(mid - 44 * 0.85 * 156_543.033_92 / 65_536) < 0.01)
    }

    @Test("A cluster tap always lands in pin mode")
    func clusterTapZoom() {
        let cluster = MapCluster(id: "x", coordinate: .init(latitude: 0, longitude: 0),
                                 items: [pin("a", 47.0, -122.0), pin("b", 49.0, -120.0)])
        #expect(MapFeatureModel.zoomToFit(cluster) >= MapFeatureModel.clusterThresholdZoom + 1)
    }
}
