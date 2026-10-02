import CoreLocation
import Foundation
import Testing
@testable import Click

@Suite("Connection location quality")
struct ConnectionLocationQualityTests {
    private typealias Quality = ConnectionLocationQuality
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func fix(
        _ accuracy: Double,
        at offset: TimeInterval,
        vertical: Double? = 6,
        fullAccuracy: Bool = true,
        floor: Int? = nil
    ) -> LocationObservation {
        LocationObservation(
            latitude: 47.6101, longitude: -122.3421,
            horizontalAccuracyMeters: accuracy, verticalAccuracyMeters: vertical,
            altitudeMeters: vertical == nil ? nil : 52.3, ellipsoidalAltitudeMeters: vertical == nil ? nil : 71.1,
            observedAt: t0.addingTimeInterval(offset), floorLevel: floor, isFullAccuracy: fullAccuracy,
            isSimulatedBySoftware: nil, isProducedByAccessory: nil
        )
    }

    private func location(horizontal: Double, vertical: Double = 8, age: TimeInterval = 0, now: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.3421),
            altitude: 52.3, horizontalAccuracy: horizontal, verticalAccuracy: vertical,
            timestamp: now.addingTimeInterval(-age)
        )
    }

    // MARK: Selection

    @Test("A slightly worse fix at the moment beats a better one seconds earlier")
    func temporalAlignment() {
        let older = fix(3, at: -2)
        let current = fix(4, at: -0.1)
        #expect(Quality.best([older, current], around: t0, until: t0) == current)
    }

    @Test("A 20 m first fix does not settle the capture; a later 8 m fix does")
    func doesNotStopAtTwentyMeters() {
        let startedAt = t0.addingTimeInterval(-1.6)
        let first = fix(20, at: -1.3)
        #expect(!Quality.isSettled(first, moment: t0, startedAt: startedAt, now: startedAt.addingTimeInterval(0.3), wait: .inFlow))
        let fixes = [first, fix(8, at: -0.2)]
        let best = Quality.best(fixes, around: t0, until: t0)
        #expect(best?.horizontalAccuracyMeters == 8)
        #expect(Quality.isSettled(best, moment: t0, startedAt: startedAt, now: t0, wait: .inFlow))
    }

    @Test("An excellent fix still waits out the minimum sampling window")
    func minimumWindow() {
        let startedAt = t0
        let excellent = fix(4, at: 0.3)
        #expect(!Quality.isSettled(excellent, moment: t0, startedAt: startedAt, now: t0.addingTimeInterval(0.4), wait: .inFlow))
        #expect(Quality.isSettled(excellent, moment: t0, startedAt: startedAt, now: t0.addingTimeInterval(1.6), wait: .inFlow))
    }

    @Test("Full-accuracy fixes win over reduced ones; coarse and stale fixes are ignored")
    func filtering() {
        let reduced = fix(3, at: 0, fullAccuracy: false)
        let full = fix(9, at: 0)
        #expect(Quality.best([reduced, full], around: t0, until: t0) == full)
        #expect(Quality.best([fix(60, at: 0)], around: t0, until: t0) == nil)
        #expect(Quality.best([fix(4, at: -9)], around: t0, until: t0) == nil)
        #expect(Quality.best([fix(4, at: 2)], around: t0, until: t0.addingTimeInterval(1)) == nil)
    }

    @Test("Ties prefer a valid vertical reading")
    func verticalTieBreak() {
        let noVertical = fix(5, at: 0, vertical: nil)
        let withVertical = fix(5.2, at: 0)
        #expect(Quality.best([noVertical, withVertical], around: t0, until: t0) == withVertical)
    }

    @Test("Deadlines: minimum window, in-flow grace, hard ceiling")
    func deadlines() {
        // Scanned 0.5 s after the scanner appeared: at least the 1.5 s minimum, grace to 1.5 s.
        #expect(Quality.deadline(moment: t0.addingTimeInterval(0.5), startedAt: t0, wait: .inFlow) == t0.addingTimeInterval(1.5))
        // Tap evidence done at 7.4 s: grace is cut at the 8 s hard limit.
        #expect(Quality.deadline(moment: t0.addingTimeInterval(7.4), startedAt: t0, wait: .inFlow) == t0.addingTimeInterval(8))
        // Long-warm capture: nothing left to wait for.
        #expect(Quality.deadline(moment: t0.addingTimeInterval(30), startedAt: t0, wait: .inFlow) < t0.addingTimeInterval(30))
        // Cold capture never waits longer than the previous scan-time timeout.
        #expect(Quality.deadline(moment: t0, startedAt: t0, wait: .cold) == t0.addingTimeInterval(Quality.coldCaptureDuration))
    }

    // MARK: Observation validation

    @Test("Negative horizontal accuracy and stale fixes are rejected")
    func rejectsInvalid() {
        let now = Date()
        #expect(LocationObservation(location(horizontal: -1, now: now), isFullAccuracy: true, maximumAge: 10, now: now) == nil)
        #expect(LocationObservation(location(horizontal: 5, age: 11, now: now), isFullAccuracy: true, maximumAge: 10, now: now) == nil)
        let nullIsland = CLLocation(latitude: 0, longitude: 0)
        #expect(LocationObservation(nullIsland, isFullAccuracy: true, maximumAge: 10, now: nullIsland.timestamp) == nil)
    }

    @Test("Invalid vertical accuracy keeps the coordinate but drops Core Location altitude")
    func invalidVertical() throws {
        let now = Date()
        let observation = try #require(
            LocationObservation(location(horizontal: 6, vertical: 0, now: now), isFullAccuracy: true, maximumAge: 10, now: now)
        )
        #expect(observation.latitude == 47.6101)
        #expect(observation.verticalAccuracyMeters == nil)
        #expect(observation.altitudeMeters == nil)
        let columns = observation.qualityColumns
        #expect(columns["gps_horizontal_accuracy_m"] as? Double == 6)
        #expect(columns["gps_vertical_accuracy_m"] == nil)
        #expect(columns["gps_altitude_m"] == nil)
    }

    @Test("Reduced accuracy is recorded, an unknown floor stays nil")
    func reducedAccuracyAndFloor() throws {
        let now = Date()
        let observation = try #require(
            LocationObservation(location(horizontal: 6, now: now), isFullAccuracy: false, maximumAge: 10, now: now)
        )
        #expect(!observation.isFullAccuracy)
        #expect(observation.floorLevel == nil)
        #expect(observation.qualityColumns["gps_full_accuracy"] as? Bool == false)
        #expect(observation.qualityColumns["gps_floor"] == nil)
        #expect(fix(4, at: 0, floor: 3).qualityColumns["gps_floor"] as? Int == 3)
    }

    // MARK: Wire payload

    @Test("Tap evidence carries this phone's own fix quality with its coordinate")
    func evidenceBody() {
        let own = fix(4.8, at: 0, floor: 3)
        let evidence = ProximityEvidence(
            myToken: "0042", heardTokens: [], detectedDevices: [],
            latitude: own.latitude, longitude: own.longitude, simulatorMock: false, location: own
        )
        let body = evidence.body
        #expect(body["latitude"] as? Double == 47.6101)
        #expect(body["gps_horizontal_accuracy_m"] as? Double == 4.8)
        #expect(body["gps_vertical_accuracy_m"] as? Double == 6)
        #expect(body["gps_floor"] as? Int == 3)
        #expect(body["gps_full_accuracy"] as? Bool == true)
        #expect(body["gps_observed_at"] is String)
    }

    @Test("Taps queued by older builds still decode")
    func legacyQueuedEvidence() throws {
        let legacy = #"{"myToken":"0042","heardTokens":["1111"],"detectedDevices":[],"latitude":47.61,"longitude":-122.34,"simulatorMock":false,"sensor":{}}"#
        let evidence = try JSONDecoder().decode(ProximityEvidence.self, from: Data(legacy.utf8))
        #expect(evidence.latitude == 47.61)
        #expect(evidence.location == nil)
        #expect(evidence.body["gps_horizontal_accuracy_m"] == nil)
    }
}

@Suite("Altimeter stabilization")
struct AltitudeStabilizerTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func sample(_ altitude: Double, accuracy: Double = 2, at offset: TimeInterval) -> AbsoluteAltitudeSample {
        AbsoluteAltitudeSample(altitudeMeters: altitude, accuracyMeters: accuracy, precisionMeters: 0.3, observedAt: t0.addingTimeInterval(offset))
    }

    @Test("One clear outlier is never chosen")
    func outlier() throws {
        let samples = [sample(50.1, at: -1.5), sample(50.3, at: -1), sample(63, at: -0.5), sample(50.2, at: 0)]
        let observation = try #require(AltitudeStabilizer.stabilized(absolute: samples, relative: [], around: t0, until: t0))
        #expect(observation.absoluteAltitudeMeters == 50.2)
        #expect(observation.accuracyMeters == 2)
    }

    @Test("Lower reported uncertainty wins, and its own uncertainty is reported")
    func prefersAccurate() throws {
        let samples = [sample(48, accuracy: 9, at: -1), sample(51.2, accuracy: 1.8, at: -0.5)]
        let observation = try #require(AltitudeStabilizer.stabilized(absolute: samples, relative: [], around: t0, until: t0))
        #expect(observation.absoluteAltitudeMeters == 51.2)
        #expect(observation.accuracyMeters == 1.8)
        #expect(observation.precisionMeters == 0.3)
    }

    @Test("Pressure and relative altitude come from the reading nearest the chosen sample")
    func pressurePairing() throws {
        let relative = [
            RelativeAltitudeSample(relativeAltitudeMeters: 0, pressureKPa: 100.80, observedAt: t0.addingTimeInterval(-3)),
            RelativeAltitudeSample(relativeAltitudeMeters: 0.2, pressureKPa: 100.82, observedAt: t0.addingTimeInterval(-0.4))
        ]
        let observation = try #require(
            AltitudeStabilizer.stabilized(absolute: [sample(51, at: -0.5)], relative: relative, around: t0, until: t0)
        )
        #expect(observation.pressureKPa == 100.82)
        #expect(observation.relativeAltitudeMeters == 0.2)
        let columns = observation.columns
        #expect(columns["exact_barometric_elevation_m"] as? Double == 51)
        #expect(columns["barometric_accuracy_m"] as? Double == 2)
        #expect(columns["barometric_pressure_kpa"] as? Double == 100.82)
    }

    @Test("Invalid and out-of-window samples are rejected")
    func rejectsInvalid() {
        let samples = [sample(.nan, at: 0), sample(50, accuracy: -1, at: 0), sample(50, at: -20)]
        #expect(AltitudeStabilizer.stabilized(absolute: samples, relative: [], around: t0, until: t0) == nil)
    }

    @Test("Sensor context sends the barometer with its uncertainty")
    func sensorColumns() {
        let barometer = AltitudeObservation(
            absoluteAltitudeMeters: 50.94, accuracyMeters: 1.6, precisionMeters: 0.3,
            relativeAltitudeMeters: nil, pressureKPa: nil, observedAt: t0
        )
        let columns = EncounterSensorContext(barometer: barometer).columns
        #expect(columns["exact_barometric_elevation_m"] as? Double == 50.9)
        #expect(columns["barometric_accuracy_m"] as? Double == 1.6)
        #expect(columns["barometric_precision_m"] as? Double == 0.3)
        #expect(columns["barometric_pressure_kpa"] == nil)
    }
}
