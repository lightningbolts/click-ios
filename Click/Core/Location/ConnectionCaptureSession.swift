import CoreLocation
import CoreMotion
import Foundation

/// Ephemeral, foreground capture for one connection flow (Tap to Connect or a QR scan). It
/// warms Core Location at the highest accuracy and the altimeter while the flow is visible,
/// keeps a small in-memory buffer of this phone's own readings, and at the connection moment
/// hands back the best observation around that instant. Nothing outlives the flow: `stop()`
/// (and the idle cap) end high-accuracy location and the altimeter and drop the buffers.
///
/// Never prompts. Callers start location only after Location snap and When-In-Use permission
/// were resolved, and the altimeter only when barometric context is opted in.
@MainActor
final class ConnectionCaptureSession: NSObject, CLLocationManagerDelegate {
    struct Snapshot: Equatable, Sendable {
        var location: LocationObservation?
        var altitude: AltitudeObservation?
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

    private var altimeter: CMAltimeter?
    private var altitudeStartedAt: Date?
    private var absoluteSamples: [AbsoluteAltitudeSample] = []
    private var relativeSamples: [RelativeAltitudeSample] = []

    private var idleStop: Task<Void, Never>?

    init(method: String, provider: LocationProvider = .shared) {
        self.method = method
        self.provider = provider
    }

    var isRunning: Bool { manager != nil || altimeter != nil }

    /// Starts whichever parts are not running yet and (re)arms the idle cap.
    func start(location: Bool, altitude: Bool) {
        if location, manager == nil, provider.isAuthorized { startLocation() }
        if altitude, altimeter == nil { startAltimeter() }
        guard isRunning else { return }
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
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        locationStartedAt = nil
        fixes = []
        updatesSeen = 0
        bestProgression = []
        altimeter?.stopAbsoluteAltitudeUpdates()
        altimeter?.stopRelativeAltitudeUpdates()
        altimeter = nil
        altitudeStartedAt = nil
        absoluteSamples = []
        relativeSamples = []
    }

    /// The best observation of this phone around `moment`. Waits only while a wait could help:
    /// until the fix is settled (`wait.settleAccuracy` after the minimum window) or the
    /// policy's deadline, and for the altimeter at most its short sampling window.
    func snapshot(at moment: Date = .now, wait: ConnectionLocationQuality.Wait) async -> Snapshot {
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
        let snapshot = Snapshot(
            location: Quality.best(fixes, around: moment, until: end),
            altitude: AltitudeStabilizer.stabilized(
                absolute: absoluteSamples, relative: relativeSamples, around: moment, until: end
            )
        )
        logDiagnostics(snapshot, moment: moment, end: end)
        if let fix = snapshot.location { provider.record(fix.asLocation) }
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
        let absolute = CMAltimeter.isAbsoluteAltitudeAvailable()
        let relative = CMAltimeter.isRelativeAltitudeAvailable()
        let status = CMAltimeter.authorizationStatus()
        guard absolute || relative, status != .denied, status != .restricted else { return }
        let altimeter = CMAltimeter()
        self.altimeter = altimeter
        altitudeStartedAt = .now
        if absolute {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let sample = AbsoluteAltitudeSample(
                    altitudeMeters: data.altitude,
                    accuracyMeters: data.accuracy,
                    precisionMeters: data.precision,
                    observedAt: Self.date(sinceBoot: data.timestamp)
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
                    observedAt: Self.date(sinceBoot: data.timestamp)
                )
                MainActor.assumeIsolated { self?.append(sample) }
            }
        }
    }

    private func append(_ sample: AbsoluteAltitudeSample) {
        absoluteSamples.append(sample)
        if absoluteSamples.count > Quality.bufferCapacity { absoluteSamples.removeFirst() }
    }

    private func append(_ sample: RelativeAltitudeSample) {
        relativeSamples.append(sample)
        if relativeSamples.count > Quality.bufferCapacity { relativeSamples.removeFirst() }
    }

    /// `CMLogItem.timestamp` counts seconds since boot.
    private nonisolated static func date(sinceBoot timestamp: TimeInterval) -> Date {
        Date(timeIntervalSinceNow: timestamp - ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Diagnostics (DEBUG, `-connection-log`; never coordinates, never telemetry)

    private func logDiagnostics(_ snapshot: Snapshot, moment: Date, end: Date) {
        #if DEBUG
        guard DebugLaunch.has("-connection-log") else { return }
        let ms = { (interval: TimeInterval) in String(Int((interval * 1000).rounded())) }
        let meters = { (value: Double?) in value.map { String(format: "%.1f", $0) } ?? "–" }
        var lines = ["method=\(method)"]
        if let locationStartedAt {
            lines.append("capture_duration_ms=\(ms(end.timeIntervalSince(locationStartedAt)))")
            lines.append("updates_seen=\(updatesSeen)")
            if let fix = snapshot.location {
                lines.append("selected:")
                lines.append("  horizontal_accuracy_m=\(meters(fix.horizontalAccuracyMeters)) tier=\(Self.tier(fix.horizontalAccuracyMeters))")
                lines.append("  vertical_accuracy_m=\(meters(fix.verticalAccuracyMeters))")
                lines.append("  age_at_connection_ms=\(ms(moment.timeIntervalSince(fix.observedAt)))")
                lines.append("  floor=\(fix.floorLevel.map(String.init) ?? "–")")
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
            lines.append("samples=\(absoluteSamples.count)")
            lines.append("altitude_m=\(meters(snapshot.altitude?.absoluteAltitudeMeters))")
            lines.append("accuracy_m=\(meters(snapshot.altitude?.accuracyMeters))")
            lines.append("precision_m=\(meters(snapshot.altitude?.precisionMeters))")
            lines.append("pressure_kpa=\(snapshot.altitude?.pressureKPa.map { String(format: "%.3f", $0) } ?? "–")")
        }
        ConnectionDebugLog.shared.note("[location] \(method)", lines.joined(separator: "\n"))
        #endif
    }

    static func tier(_ accuracy: CLLocationAccuracy) -> String {
        switch accuracy {
        case ...Quality.excellentAccuracy: "excellent"
        case ...Quality.goodAccuracy: "good"
        case ...Quality.usableAccuracy: "usable"
        case ...Quality.maximumUsefulAccuracy: "coarse"
        default: "unusable"
        }
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
