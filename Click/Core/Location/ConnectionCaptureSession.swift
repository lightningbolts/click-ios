import CoreLocation
import CoreMotion
import Foundation

/// Ephemeral, foreground capture for one connection flow (Tap to Connect or a QR scan). While
/// the flow is visible it warms Core Location at the highest accuracy (plus heading), the
/// altimeter and a 25 Hz device-motion stream, keeps small in-memory buffers of this phone's
/// own readings, and at the connection moment hands back everything around that instant.
/// Nothing outlives the flow: `stop()` (and the idle cap) end every sensor and drop the buffers.
/// The one exception is an altimeter explicitly handed off to `EncounterAltitudeFollowUp`,
/// which stops it within seconds.
///
/// Never prompts. Callers start location only after Location snap and When-In-Use permission
/// were resolved, and the altimeter only when barometric context is opted in. Device motion
/// needs no permission (it already fed the connect-time hardware snapshot).
@MainActor
final class ConnectionCaptureSession: NSObject, CLLocationManagerDelegate {
    /// This phone's readings around one connection moment.
    struct Snapshot: Equatable, Sendable {
        var moment = Date.now
        /// `moment` on the monotonic sensor clock.
        var momentUptime = SensorClock.uptime
        var startedAt: Date?
        var finishedAt = Date.now
        var location: LocationObservation?
        /// Every useful fix in the selection window (for the fused estimate and the trail).
        var locationFixes: [LocationObservation] = []
        var locationUpdates = 0
        var altitude: AltitudeObservation?
        /// When the altimeter started, so the time to its first absolute fix can be measured.
        var altitudeStartedAt: Date?
        var absoluteAltitudeSamples: [AbsoluteAltitudeSample] = []
        var relativeAltitudeSamples: [RelativeAltitudeSample] = []
        var motionSamples: [MotionSample] = []
        var heading: HeadingSample?
        var activity: ConnectionSensorObservation.Activity?
        var pedometer: ConnectionSensorObservation.Pedometer?
    }

    private typealias Quality = ConnectionLocationQuality

    /// "tap" / "qr" / "link", for diagnostics only.
    let method: String
    private let provider: LocationProvider

    private var manager: CLLocationManager?
    private var locationStartedAt: Date?
    private var fixes: [LocationObservation] = []
    private var updatesSeen = 0
    private var bestProgression: [Double] = []
    private var latestHeading: HeadingSample?

    private var altimeter: AltimeterFeed?
    private var altitudeStartedAt: Date? { altimeter?.startedAt }
    private var absoluteSamples: [AbsoluteAltitudeSample] { altimeter?.absoluteSamples ?? [] }
    private var relativeSamples: [RelativeAltitudeSample] { altimeter?.relativeSamples ?? [] }

    private var motionManager: CMMotionManager?
    private var motionSamples: [MotionSample] = []
    /// Device-motion history kept while warm: enough for the window around the moment.
    private static let motionHistory: TimeInterval = 10
    private static let motionCapacity = 300

    private var startedAt: Date?
    private var idleStop: Task<Void, Never>?

    init(method: String, provider: LocationProvider = .shared) {
        self.method = method
        self.provider = provider
    }

    var isRunning: Bool { manager != nil || altimeter != nil || motionManager != nil }

    /// Starts whichever parts are not running yet and (re)arms the idle cap.
    func start(location: Bool, altitude: Bool, motion: Bool = true) {
        if location, manager == nil, provider.isAuthorized { startLocation() }
        if altitude, altimeter == nil { startAltimeter() }
        if motion, motionManager == nil { startMotion() }
        guard isRunning else { return }
        if startedAt == nil { startedAt = .now }
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Quality.maximumWarmDuration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        idleStop?.cancel()
        idleStop = nil
        startedAt = nil
        manager?.stopUpdatingLocation()
        manager?.stopUpdatingHeading()
        manager?.delegate = nil
        manager = nil
        locationStartedAt = nil
        fixes = []
        updatesSeen = 0
        bestProgression = []
        latestHeading = nil
        altimeter?.stop()
        altimeter = nil
        motionManager?.stopDeviceMotionUpdates()
        motionManager = nil
        motionSamples = []
    }

    /// Everything this phone measured around `moment`. Waits only while a wait could help:
    /// until the fix is settled (`wait.settleAccuracy` after the minimum window) or the
    /// policy's deadline, and for the altimeter at most its short sampling window. Motion is
    /// never waited for: the window holds what arrived before submission.
    func snapshot(at moment: Date = .now, wait: ConnectionLocationQuality.Wait) async -> Snapshot {
        async let activity = MotionContextSampler.activity(at: moment)
        async let pedometer = MotionContextSampler.pedometer(at: moment)
        let altitudeDeadline = altitudeStartedAt.map { $0.addingTimeInterval(AltitudeStabilizer.sampleWindow) }
        while !Task.isCancelled {
            let now = Date.now
            let locationDone = locationStartedAt.map { startedAt in
                now >= Quality.deadline(moment: moment, startedAt: startedAt, wait: wait) || Quality.isSettled(
                    Quality.best(fixes, around: moment, until: now),
                    moment: moment, startedAt: startedAt, now: now, wait: wait
                )
            } ?? true
            let altitudeDone = altitudeDeadline.map { now >= $0 || !absoluteSamples.isEmpty } ?? true
            if locationDone && altitudeDone { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let end = Date.now
        let earliest = moment.addingTimeInterval(-Quality.selectionLookback)
        let fix = Quality.best(fixes, around: moment, until: end)
        let snapshot = Snapshot(
            moment: moment,
            momentUptime: SensorClock.stamp(for: moment, now: end),
            startedAt: startedAt,
            finishedAt: end,
            location: fix,
            locationFixes: fixes.filter { Quality.isUseful($0) && $0.observedAt >= earliest && $0.observedAt <= end },
            locationUpdates: updatesSeen,
            altitude: AltitudeStabilizer.stabilized(
                absolute: absoluteSamples, relative: relativeSamples, around: moment, until: end
            ),
            altitudeStartedAt: altitudeStartedAt,
            absoluteAltitudeSamples: absoluteSamples.filter { $0.observedAt >= earliest && $0.observedAt <= end },
            relativeAltitudeSamples: relativeSamples.filter { $0.observedAt >= earliest && $0.observedAt <= end },
            motionSamples: motionSamples,
            heading: latestHeading.flatMap { $0.observedAt >= earliest ? $0 : nil },
            activity: await activity,
            pedometer: await pedometer
        )
        logDiagnostics(snapshot)
        if let fix { provider.record(fix.asLocation) }
        return snapshot
    }

    // MARK: - Core Location

    private func startLocation() {
        let manager = CLLocationManager()
        manager.delegate = self
        // Highest quality, only for this short user-initiated window; never left running.
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        self.manager = manager
        locationStartedAt = .now
        // A fresh cached fix may seed the buffer, tagged with its real timestamp. Reduced
        // accuracy is recorded on every observation rather than hidden.
        let fullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        for seed in [manager.location, provider.lastFix].compactMap({ $0 }) {
            if let fix = LocationObservation(seed, isFullAccuracy: fullAccuracy, maximumAge: Quality.maximumSeedAge) {
                ingest(fix)
            }
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = kCLHeadingFilterNone
            manager.startUpdatingHeading()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        let observations = locations.compactMap {
            LocationObservation($0, isFullAccuracy: fullAccuracy, maximumAge: Quality.maximumSeedAge)
        }
        let source = ObjectIdentifier(manager)
        Task { @MainActor in
            guard let current = self.manager, ObjectIdentifier(current) == source else { return }
            for fix in observations { self.ingest(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let sample = HeadingSample(newHeading)
        let source = ObjectIdentifier(manager)
        Task { @MainActor in
            guard let current = self.manager, ObjectIdentifier(current) == source else { return }
            self.latestHeading = sample
        }
    }

    /// Never interrupts a connection with the system's compass-calibration screen.
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func ingest(_ fix: LocationObservation) {
        guard !fixes.contains(where: { $0.observedAt == fix.observedAt }) else { return }
        updatesSeen += 1
        fixes.append(fix)
        if fixes.count > Quality.bufferCapacity { fixes.removeFirst(fixes.count - Quality.bufferCapacity) }
        if bestProgression.last.map({ fix.horizontalAccuracyMeters < $0 }) ?? true {
            bestProgression.append(fix.horizontalAccuracyMeters)
        }
    }

    // MARK: - Altimeter

    private func startAltimeter() {
        altimeter = AltimeterFeed(capacity: Quality.bufferCapacity)
    }

    /// Hands the running altimeter to the caller when it can still deliver the absolute fix
    /// this capture missed. The capture forgets it (its `stop()` no longer ends it), so the
    /// caller must stop it. Nil when there is nothing to hand off.
    func handOffAltimeterAwaitingAbsoluteFix() -> AltimeterFeed? {
        guard let feed = altimeter, feed.isRunning, feed.providesAbsoluteAltitude else { return nil }
        altimeter = nil
        return feed
    }

    // MARK: - Device motion

    private func startMotion() {
        let motion = CMMotionManager()
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1 / Double(MotionObservation.sampleRateHz)
        // A magnetometer-referenced frame also yields the calibrated magnetic field.
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical
            : (frames.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical)
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, _ in
            guard let data else { return }
            let sample = MotionSample(data)
            MainActor.assumeIsolated { self?.append(sample) }
        }
        motionManager = motion
    }

    private func append(_ sample: MotionSample) {
        motionSamples.append(sample)
        let horizon = sample.uptime - Self.motionHistory
        if let stale = motionSamples.firstIndex(where: { $0.uptime >= horizon }), stale > 0 {
            motionSamples.removeFirst(stale)
        }
        if motionSamples.count > Self.motionCapacity { motionSamples.removeFirst(motionSamples.count - Self.motionCapacity) }
    }

    // MARK: - Diagnostics (DEBUG, `-connection-log`; never coordinates, never telemetry)

    private func logDiagnostics(_ snapshot: Snapshot) {
        #if DEBUG
        guard DebugLaunch.has("-connection-log") else { return }
        let ms = { (interval: TimeInterval) in String(Int((interval * 1000).rounded())) }
        let meters = { (value: Double?) in value.map { String(format: "%.1f", $0) } ?? "–" }
        var lines = ["method=\(method)"]
        if let locationStartedAt {
            lines.append("capture_duration_ms=\(ms(snapshot.finishedAt.timeIntervalSince(locationStartedAt)))")
            lines.append("updates_seen=\(updatesSeen)")
            if let fix = snapshot.location {
                lines.append("selected:")
                lines.append("  horizontal_accuracy_m=\(meters(fix.horizontalAccuracyMeters)) tier=\(Quality.tier(fix.horizontalAccuracyMeters))")
                lines.append("  vertical_accuracy_m=\(meters(fix.verticalAccuracyMeters))")
                lines.append("  age_at_connection_ms=\(ms(snapshot.moment.timeIntervalSince(fix.observedAt)))")
                lines.append("  floor=\(fix.floorLevel.map(String.init) ?? "–")")
                lines.append("  speed_mps=\(meters(fix.speedMetersPerSecond))")
                lines.append("  full_accuracy=\(fix.isFullAccuracy)")
                if fix.isSimulatedBySoftware == true { lines.append("  simulated=true") }
            } else {
                lines.append("selected: none")
            }
            if let first = fixes.first { lines.append("first_candidate: horizontal_accuracy_m=\(meters(first.horizontalAccuracyMeters))") }
            lines.append("best_progression: " + bestProgression.map { meters($0) }.joined(separator: " -> "))
        }
        if altitudeStartedAt != nil {
            lines.append("[altimeter]")
            lines.append("samples=\(snapshot.absoluteAltitudeSamples.count)")
            lines.append("altitude_m=\(meters(snapshot.altitude?.absoluteAltitudeMeters))")
            lines.append("accuracy_m=\(meters(snapshot.altitude?.accuracyMeters))")
            lines.append("precision_m=\(meters(snapshot.altitude?.precisionMeters))")
            lines.append("pressure_kpa=\(snapshot.altitude?.pressureKPa.map { String(format: "%.3f", $0) } ?? "–")")
        }
        ConnectionDebugLog.shared.note("[location] \(method)", lines.joined(separator: "\n"))
        #endif
    }
}

extension HeadingSample {
    /// Negative heading values mean "invalid" in Core Location; they become nil.
    init(_ heading: CLHeading) {
        let valid = { (value: Double) -> Double? in value.isFinite && value >= 0 ? value : nil }
        let field = [heading.x, heading.y, heading.z]
        self.init(
            magneticHeading: valid(heading.magneticHeading),
            trueHeading: valid(heading.trueHeading),
            headingAccuracy: valid(heading.headingAccuracy),
            field: field.allSatisfy(\.isFinite) ? field : nil,
            observedAt: heading.timestamp
        )
    }
}

private extension LocationObservation {
    /// Rebuilt only to share the chosen fix with other features via `LocationProvider.lastFix`.
    var asLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitudeMeters ?? 0,
            horizontalAccuracy: horizontalAccuracyMeters,
            verticalAccuracy: verticalAccuracyMeters ?? -1,
            timestamp: observedAt
        )
    }
}
