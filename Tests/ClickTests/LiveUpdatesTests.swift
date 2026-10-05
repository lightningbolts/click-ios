import CoreLocation
import Testing
@testable import Click

@Suite("Live updates")
struct LiveUpdatesTests {
    private let manhattan = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)

    @Test func anywhereChangeAffectsEveryRead() {
        let change = BeaconChange(revision: 1, cells: nil)
        #expect(change.affects(manhattan))
        #expect(change.affects(nil))
    }

    @Test func unknownCenterIsAffected() {
        let change = BeaconChange(revision: 1, cells: [LiveCell(latitude: 51.5, longitude: -0.1)])
        #expect(change.affects(nil))
    }

    @Test func nearbyCellAffectsAndDistantCellDoesNot() {
        let brooklyn = BeaconChange(revision: 1, cells: [LiveCell(latitude: 40.7, longitude: -73.9)])
        let london = BeaconChange(revision: 2, cells: [LiveCell(latitude: 51.5, longitude: -0.1)])
        #expect(brooklyn.affects(manhattan))
        #expect(!london.affects(manhattan))
    }

    @Test func edgeOfRadiusStillCounts() {
        // ~55 km north: past the 50 km discovery radius, but inside it once the cell's rounding is allowed for.
        let change = BeaconChange(revision: 1, cells: [LiveCell(latitude: 41.25, longitude: -73.99)])
        #expect(change.affects(manhattan))
        let far = BeaconChange(revision: 1, cells: [LiveCell(latitude: 41.5, longitude: -73.99)])
        #expect(!far.affects(manhattan))
    }
}
