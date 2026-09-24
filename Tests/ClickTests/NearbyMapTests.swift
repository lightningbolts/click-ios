import CoreLocation
import Testing
@testable import Click

@Suite("Nearby sheet and map clustering")
struct NearbyMapTests {
    @Test("Content fades in over the first 60 pt above the lip")
    func contentOpacity() {
        #expect(NearbySheet.contentOpacity(height: NearbySheet.lipHeight) == 0)
        #expect(NearbySheet.contentOpacity(height: NearbySheet.lipHeight + 30) == 0.5)
        #expect(NearbySheet.contentOpacity(height: 600) == 1)
    }

    @Test("A fling snaps to the detent nearest the projected rest height")
    func snapUsesProjection() {
        let available: CGFloat = 800
        #expect(NearbySheet.settledDetent(projectedHeight: 90, available: available) == .lip)
        #expect(NearbySheet.settledDetent(projectedHeight: 380, available: available) == .medium)
        #expect(NearbySheet.settledDetent(projectedHeight: 1_200, available: available) == .expanded)
    }

    private func pin(_ id: String, _ lat: Double, _ lon: Double) -> MapItem {
        MapItem(kind: .person(ConnectionPin(connectionID: id, userID: id, displayName: id, avatarURL: nil,
                                            latitude: lat, longitude: lon, locationName: nil, isCore: false)))
    }

    @Test("Zoomed in, every pin stands alone; zoomed out, close pins merge")
    func clustering() {
        let items = [pin("a", 47.6200, -122.3200), pin("b", 47.6250, -122.3240), pin("c", 47.9, -122.9)]
        #expect(MapFeatureModel.clusters(items, latitudeDelta: 0.02).count == 3)
        let zoomedOut = MapFeatureModel.clusters(items, latitudeDelta: 1.0)
        #expect(zoomedOut.count == 2)
        #expect(zoomedOut.contains { $0.items.count == 2 })
    }
}
