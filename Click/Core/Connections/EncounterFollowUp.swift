import CoreLocation
import CoreMotion
import Foundation
import Observation

/// Refines this phone's readings of a connection in the seconds after it, while the people who
/// just met are still together on the result screen, so the connect itself never waits:
///
/// - **Altitude.** A quick QR scan or tap usually completes before the altimeter's first
///   absolute fix. The capture's running altimeter is taken over until a fix arrives (at most
///   `AltitudeStabilizer.followUpWindow` after the moment), and the altitude at the moment is
///   sent to `POST /api/connections/encounter-altitude`.
/// - **Location.** GPS keeps converging for tens of seconds. Location keeps running for
///   `ConnectionLocationQuality.refinementWindow` while the phone stays still, and a clearly
///   tighter fix of the same spot is sent to `POST /api/connections/encounter-location`.
///   `refinedAccuracyMeters` shows it on the result as it improves.
///
/// Readings are sent once the flow confirms which connections it logged; the server fills only
/// this user's rows for that exact moment and never makes a stored reading worse. Nothing is
/// sent when the flow cancels, never confirms, or nothing better arrives; failures are silent
/// (the connection is unaffected).
@Observable
@MainActor
final class EncounterFollowUp {
    /// After the readings, how long the flow has to confirm the connections it logged (a tap
    /// can wait for its peer and the people review).
    static let confirmationWindow: TimeInterval = 120
    static let maximumConnections = 20
    private static let pollInterval: Duration = .milliseconds(250)

    /// The radius of the tightest fix of the moment so far, once better than the capture's.
    private(set) var refinedAccuracyMeters: Double?

    private let altimeter: AltimeterFeed?
    private let location: StillLocationFeed?
    private let originalFix: LocationObservation?
    private let moment: Date
    private let api: ClickAPIClient
    @ObservationIgnored private var connectionIDs: [String]?
    @ObservationIgnored private var isCancelled = false

    private init(altimeter: AltimeterFeed?, location: StillLocationFeed?, originalFix: LocationObservation?, moment: Date, api: ClickAPIClient) {
        self.altimeter = altimeter
        self.location = location
        self.originalFix = originalFix
        self.moment = moment
        self.api = api
    }

    /// Starts a follow-up when the snapshot has no absolute altitude and the capture's altimeter
    /// can still provide one, or its fix could still tighten; otherwise nil. Call before the
    /// capture stops, so location keeps running without a gap.
    static func begin(
        from capture: ConnectionCaptureSession,
        snapshot: ConnectionCaptureSession.Snapshot,
        api: ClickAPIClient
    ) -> EncounterFollowUp? {
        let altimeter = snapshot.altitude?.absoluteAltitudeMeters == nil ? capture.handOffAltimeterAwaitingAbsoluteFix() : nil
        let fix = snapshot.location
        let location = fix.flatMap {
            $0.horizontalAccuracyMeters > ConnectionLocationQuality.excellentAccuracy
                ? StillLocationFeed(capacity: ConnectionLocationQuality.bufferCapacity) : nil
        }
        guard altimeter != nil || location != nil else { return nil }
        let followUp = EncounterFollowUp(altimeter: altimeter, location: location, originalFix: fix, moment: snapshot.moment, api: api)
        Task { await followUp.run() }
        return followUp
    }

    /// The flow logged encounters on these connections; readings are sent for them once known.
    func confirm(connectionIDs ids: [String]) {
        guard !isCancelled, connectionIDs == nil else { return }
        var seen = Set<String>()
        connectionIDs = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.maximumConnections))
    }

    /// The connection did not happen: stop the sensors and send nothing. Ignored once
    /// confirmed, so closing the result screen never drops a logged encounter's readings.
    func cancel() {
        guard connectionIDs == nil else { return }
        isCancelled = true
        refinedAccuracyMeters = nil
        altimeter?.stop()
        location?.stop()
    }

    private func run() async {
        async let altitudeReading = altitude()
        async let locationReading = refinedLocation()
        let (altitude, location) = await (altitudeReading, locationReading)
        guard !isCancelled, altitude != nil || location != nil else { return }

        let confirmDeadline = Date.now.addingTimeInterval(Self.confirmationWindow)
        while !isCancelled, connectionIDs == nil, Date.now < confirmDeadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
        guard !isCancelled, let ids = connectionIDs, !ids.isEmpty else { return }
        if let altitude, let body = Self.altitudeBody(altitude, moment: moment, connectionIDs: ids) {
            await post("/api/connections/encounter-altitude", body)
        }
        if let location {
            await post("/api/connections/encounter-location", Self.locationBody(location, moment: moment, connectionIDs: ids))
        }
    }

    private func post(_ path: String, _ body: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        _ = try? await api.executeRaw(APIRequest(path: path, method: .post, body: data, requiresAuth: true))
    }

    /// The altitude at the moment, from the first usable absolute fix.
    private func altitude() async -> AltitudeObservation? {
        guard let feed = altimeter else { return nil }
        defer { feed.stop() }
        let deadline = moment.addingTimeInterval(AltitudeStabilizer.followUpWindow)
        while !isCancelled, feed.isRunning {
            let now = Date.now
            if let reading = AltitudeStabilizer.followUp(
                absolute: feed.absoluteSamples, relative: feed.relativeSamples, moment: moment, until: now
            ) { return reading }
            if now >= deadline { return nil }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return nil
    }

    /// The tightest fix of the moment's spot while the phone stays still, published as it
    /// improves; nil unless clearly better than the capture's.
    private func refinedLocation() async -> LocationObservation? {
        guard let feed = location, let originalFix else { return nil }
        defer { feed.stop() }
        let deadline = moment.addingTimeInterval(ConnectionLocationQuality.refinementWindow)
        var refined: LocationObservation?
        while !isCancelled, feed.isRunning, Date.now < deadline {
            if let next = ConnectionLocationQuality.refined(originalFix, later: feed.fixes, moment: moment),
               next.horizontalAccuracyMeters < refined?.horizontalAccuracyMeters ?? .infinity {
                refined = next
                refinedAccuracyMeters = next.horizontalAccuracyMeters
            }
            // Nothing tighter is worth waiting for once the phone moved or the fix is excellent.
            if feed.hasMoved || (refined?.horizontalAccuracyMeters ?? .infinity) <= ConnectionLocationQuality.excellentAccuracy { break }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return isCancelled ? nil : refined
    }

    /// `POST /api/connections/encounter-altitude` body. `connection_moment` uses the same
    /// encoding as `sensor_observation.connection_moment`, which the server matches it against.
    nonisolated static func altitudeBody(_ reading: AltitudeObservation, moment: Date, connectionIDs: [String]) -> [String: Any]? {
        guard let altitude = reading.absoluteAltitudeMeters, altitude.isFinite, !connectionIDs.isEmpty else { return nil }
        var body = timing(moment: moment, observedAt: reading.observedAt, connectionIDs: connectionIDs)
        body["exact_barometric_elevation_m"] = LocationObservation.rounded(altitude, places: 1)
        if let accuracy = reading.accuracyMeters, accuracy.isFinite {
            body["barometric_accuracy_m"] = LocationObservation.rounded(accuracy, places: 2)
        }
        if let precision = reading.precisionMeters, precision.isFinite {
            body["barometric_precision_m"] = LocationObservation.rounded(precision, places: 2)
        }
        return body
    }

    /// `POST /api/connections/encounter-location` body.
    nonisolated static func locationBody(_ fix: LocationObservation, moment: Date, connectionIDs: [String]) -> [String: Any] {
        var body = timing(moment: moment, observedAt: fix.observedAt, connectionIDs: connectionIDs)
        body["gps_lat"] = fix.latitude
        body["gps_lon"] = fix.longitude
        body["gps_horizontal_accuracy_m"] = LocationObservation.rounded(fix.horizontalAccuracyMeters, places: 2)
        return body
    }

    private nonisolated static func timing(moment: Date, observedAt: Date, connectionIDs: [String]) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "connection_ids": connectionIDs,
            "connection_moment": formatter.string(from: moment),
            "observed_at": formatter.string(from: observedAt)
        ]
    }
}

/// Location fixes for the refinement, kept only while the phone stays still: walking (seconds of
/// sustained linear acceleration) or a fix reporting speed ends collection, since later fixes would
/// describe somewhere else. Stops itself after the refinement window.
@MainActor
private final class StillLocationFeed: NSObject, CLLocationManagerDelegate {
    private(set) var fixes: [LocationObservation] = []
    private(set) var hasMoved = false
    private var manager: CLLocationManager?
    private var motion: CMMotionManager?
    /// Squared linear acceleration (g²) of the current second's samples.
    private var secondEnergy: [Double] = []
    /// Consecutive seconds with sustained acceleration (walking, not lifting the phone once).
    private var activeSeconds = 0
    private let capacity: Int
    private static let motionRateHz = 10

    init(capacity: Int) {
        self.capacity = capacity
        super.init()
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
        self.manager = manager

        let motion = CMMotionManager()
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / Double(Self.motionRateHz)
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.userAcceleration else { return }
                let energy = a.x * a.x + a.y * a.y + a.z * a.z
                MainActor.assumeIsolated { self?.record(energy) }
            }
            self.motion = motion
        }
    }

    var isRunning: Bool { manager != nil }

    /// Stops location and motion; collected fixes stay readable. Safe to call twice.
    func stop() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        motion?.stopDeviceMotionUpdates()
        motion = nil
    }

    private func record(_ energy: Double) {
        secondEnergy.append(energy)
        guard secondEnergy.count == Self.motionRateHz else { return }
        let rms = (secondEnergy.reduce(0, +) / Double(secondEnergy.count)).squareRoot()
        secondEnergy.removeAll(keepingCapacity: true)
        activeSeconds = rms > ConnectionLocationQuality.stationaryAccelerationRMS ? activeSeconds + 1 : 0
        if activeSeconds >= ConnectionLocationQuality.movingSeconds { markMoved() }
    }

    private func markMoved() {
        hasMoved = true
        stop()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        let observations = locations.compactMap {
            LocationObservation($0, isFullAccuracy: fullAccuracy, maximumAge: ConnectionLocationQuality.maximumSeedAge)
        }
        let source = ObjectIdentifier(manager)
        Task { @MainActor in
            guard let current = self.manager, ObjectIdentifier(current) == source else { return }
            for fix in observations {
                if (fix.speedMetersPerSecond ?? 0) >= ConnectionLocationQuality.stationarySpeed {
                    self.markMoved()
                    return
                }
                self.fixes.append(fix)
            }
            if self.fixes.count > self.capacity { self.fixes.removeFirst(self.fixes.count - self.capacity) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
