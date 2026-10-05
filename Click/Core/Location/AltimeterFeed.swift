import CoreMotion
import Foundation

/// One running altimeter and the readings it has delivered. A connection capture owns it while
/// the flow is visible; when the connection completes before the first absolute fix, the
/// capture hands it to `EncounterAltitudeFollowUp`, which keeps it alive for a few more seconds
/// and then stops it. Exactly one owner stops it.
@MainActor
final class AltimeterFeed {
    let startedAt = Date.now
    let providesAbsoluteAltitude: Bool
    private(set) var absoluteSamples: [AbsoluteAltitudeSample] = []
    private(set) var relativeSamples: [RelativeAltitudeSample] = []
    private var altimeter: CMAltimeter?
    private let capacity: Int

    /// Nil when this device has no altimeter or the user denied motion access.
    init?(capacity: Int) {
        let absolute = CMAltimeter.isAbsoluteAltitudeAvailable()
        let relative = CMAltimeter.isRelativeAltitudeAvailable()
        let status = CMAltimeter.authorizationStatus()
        guard absolute || relative, status != .denied, status != .restricted else { return nil }
        self.capacity = capacity
        providesAbsoluteAltitude = absolute
        let altimeter = CMAltimeter()
        self.altimeter = altimeter
        // Handlers run on the main queue, so `assumeIsolated` holds.
        if absolute {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let sample = AbsoluteAltitudeSample(
                    altitudeMeters: data.altitude,
                    accuracyMeters: data.accuracy,
                    precisionMeters: data.precision,
                    observedAt: SensorClock.date(atUptime: data.timestamp)
                )
                MainActor.assumeIsolated { self?.append(sample) }
            }
        }
        if relative {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let sample = RelativeAltitudeSample(
                    relativeAltitudeMeters: data.relativeAltitude.doubleValue,
                    pressureKPa: data.pressure.doubleValue,
                    observedAt: SensorClock.date(atUptime: data.timestamp)
                )
                MainActor.assumeIsolated { self?.append(sample) }
            }
        }
    }

    var isRunning: Bool { altimeter != nil }

    /// Stops both streams; the readings already delivered stay readable. Safe to call twice.
    func stop() {
        altimeter?.stopAbsoluteAltitudeUpdates()
        altimeter?.stopRelativeAltitudeUpdates()
        altimeter = nil
    }

    private func append(_ sample: AbsoluteAltitudeSample) {
        guard isRunning else { return }
        absoluteSamples.append(sample)
        if absoluteSamples.count > capacity { absoluteSamples.removeFirst() }
    }

    private func append(_ sample: RelativeAltitudeSample) {
        guard isRunning else { return }
        relativeSamples.append(sample)
        if relativeSamples.count > capacity { relativeSamples.removeFirst() }
    }
}
