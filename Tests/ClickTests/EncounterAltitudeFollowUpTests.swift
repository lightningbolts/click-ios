import Foundation
import Testing
@testable import Click

@Suite("Encounter altitude follow-up")
struct EncounterAltitudeFollowUpTests {
    private let moment = Date(timeIntervalSince1970: 1_790_000_000.123)

    private func fix(_ altitude: Double, at offset: TimeInterval, accuracy: Double = 3) -> AbsoluteAltitudeSample {
        AbsoluteAltitudeSample(
            altitudeMeters: altitude, accuracyMeters: accuracy, precisionMeters: 0.5,
            observedAt: moment.addingTimeInterval(offset)
        )
    }

    private func height(_ meters: Double, at offset: TimeInterval) -> RelativeAltitudeSample {
        RelativeAltitudeSample(relativeAltitudeMeters: meters, pressureKPa: 101.3, observedAt: moment.addingTimeInterval(offset))
    }

    @Test("A late fix is corrected for the height gained after the moment")
    func correctedForClimb() throws {
        let relative = stride(from: -1.0, through: 9.0, by: 1).map { height($0 <= 0 ? 0 : $0 * 0.4, at: $0) }
        let reading = try #require(AltitudeStabilizer.followUp(
            absolute: [fix(120, at: 9)], relative: relative, moment: moment, until: moment.addingTimeInterval(10)
        ))
        // 3.6 m climbed between the moment and the fix.
        #expect(abs((reading.absoluteAltitudeMeters ?? 0) - 116.4) < 1e-9)
        #expect(reading.accuracyMeters == 3)
        #expect(reading.observedAt == moment.addingTimeInterval(9))
        #expect(reading.pressureKPa == nil)
    }

    @Test("Without relative readings only a fix close to the moment is used")
    func uncorrectedLimit() {
        let until = moment.addingTimeInterval(AltitudeStabilizer.followUpWindow)
        let near = AltitudeStabilizer.followUp(absolute: [fix(50, at: 4)], relative: [], moment: moment, until: until)
        #expect(near?.absoluteAltitudeMeters == 50)
        let far = AltitudeStabilizer.followUp(absolute: [fix(50, at: 8)], relative: [], moment: moment, until: until)
        #expect(far == nil)
        // A stale relative reading is no correction either.
        let stale = AltitudeStabilizer.followUp(
            absolute: [fix(50, at: 12)], relative: [height(0, at: -1)], moment: moment, until: until
        )
        #expect(stale == nil)
    }

    @Test("No usable fix yet means no reading")
    func noFix() {
        let until = moment.addingTimeInterval(3)
        #expect(AltitudeStabilizer.followUp(absolute: [], relative: [height(0, at: 1)], moment: moment, until: until) == nil)
        #expect(AltitudeStabilizer.followUp(absolute: [fix(.nan, at: 1)], relative: [], moment: moment, until: until) == nil)
        // A fix after `until` has not arrived yet.
        #expect(AltitudeStabilizer.followUp(absolute: [fix(50, at: 4)], relative: [], moment: moment, until: until) == nil)
    }

    @Test("The request matches the stored connection moment and rounds the reading")
    func body() throws {
        let reading = AltitudeObservation(
            absoluteAltitudeMeters: 116.437, accuracyMeters: 2.345, precisionMeters: nil,
            relativeAltitudeMeters: nil, pressureKPa: nil, observedAt: moment.addingTimeInterval(9)
        )
        let body = try #require(EncounterAltitudeFollowUp.body(reading, moment: moment, connectionIDs: ["a", "b"]))
        #expect(body["connection_ids"] as? [String] == ["a", "b"])
        #expect(body["connection_moment"] as? String == "2026-09-21T14:13:20.123Z")
        #expect(body["observed_at"] as? String == "2026-09-21T14:13:29.123Z")
        #expect(body["exact_barometric_elevation_m"] as? Double == 116.4)
        #expect(body["barometric_accuracy_m"] as? Double == 2.35)
        #expect(body["barometric_precision_m"] == nil)

        #expect(EncounterAltitudeFollowUp.body(reading, moment: moment, connectionIDs: []) == nil)
        let noAltitude = AltitudeObservation(
            absoluteAltitudeMeters: nil, accuracyMeters: nil, precisionMeters: nil,
            relativeAltitudeMeters: 0, pressureKPa: 101, observedAt: moment
        )
        #expect(EncounterAltitudeFollowUp.body(noAltitude, moment: moment, connectionIDs: ["a"]) == nil)
    }
}
