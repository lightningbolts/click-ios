import CoreLocation
import AVFoundation
import CoreMotion
import Foundation
import NearbyInteraction
import UIKit

/// Monotonic clock for relative sensor timing (seconds since boot; never jumps with wall-clock
/// changes). Wall-clock `Date`s are kept only for backend correlation.
enum SensorClock {
    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The monotonic stamp that corresponded to `date`.
    static func stamp(for date: Date, now: Date = .now, nowUptime: TimeInterval = SensorClock.uptime) -> TimeInterval {
        nowUptime - now.timeIntervalSince(date)
    }

    /// The wall-clock time of a monotonic stamp (e.g. `CMLogItem.timestamp`).
    static func date(atUptime stamp: TimeInterval, now: Date = .now, nowUptime: TimeInterval = SensorClock.uptime) -> Date {
        now.addingTimeInterval(stamp - nowUptime)
    }

    static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }
}

/// One phone's versioned record of a connection (spec: connection sensor capture §3, §37): the
/// raw, minimally processed readings of its own sensors during the bounded capture, aligned on
/// one connection moment. Every `*_ms` timeline value is relative to `connection_moment`.
/// Derived product fields (`motion_variance`, `elevation_category`, …) stay separate and never
/// replace these. Never contains audio, camera frames, Wi-Fi lists or unrelated BLE devices.
public struct ConnectionSensorObservation: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    /// Stays under the server's 64 KB cap; motion samples are dropped first (summary kept).
    static let maximumPayloadBytes = 56 * 1024

    var schemaVersion = ConnectionSensorObservation.currentSchemaVersion
    /// "tap" / "qr" / "link".
    var method: String
    var capturedAt: Date?
    var connectionMoment: Date
    var captureDurationMs: Int?
    var location: Location?
    var barometer: Barometer?
    var motion: MotionObservation?
    var heading: Heading?
    var activity: Activity?
    var pedometer: Pedometer?
    var bluetooth: BluetoothObservation?
    var acoustic: AcousticObservation?
    /// Reserved for Nearby Interaction ranging. Optional; never required to connect.
    var uwb: UWB?
    var device: Device?
    /// This phone's clock when the observation was sent; the server stamps its own receipt time
    /// beside it, so two phones' timelines can be aligned despite clock skew.
    var clock: Clock?

    struct Clock: Codable, Equatable, Sendable {
        var sentAt: Date
        var timeZoneOffsetS: Int
    }

    struct Location: Codable, Equatable, Sendable {
        var lat: Double
        var lon: Double
        var horizontalAccuracyM: Double
        var altitudeMslM: Double?
        var ellipsoidalAltitudeM: Double?
        var verticalAccuracyM: Double?
        var speedMps: Double?
        var speedAccuracyMps: Double?
        var courseDeg: Double?
        var courseAccuracyDeg: Double?
        var floor: Int?
        var fullAccuracy: Bool
        var observedAt: Date
        var ageAtMomentMs: Int
        var simulated: Bool?
        var externalAccessory: Bool?
        var updatesSeen: Int
        /// Consistent fixes combined (see `ConnectionLocationQuality.fused`); the fix above stays canonical.
        var fused: Fused?
        /// The fixes nearest the moment, oldest first, for analysis beyond the single best fix.
        var trail: [TrailFix]?

        static let maximumTrail = 8

        struct Fused: Codable, Equatable, Sendable {
            var lat: Double
            var lon: Double
            var radiusM: Double
            var fixCount: Int
            var spanMs: Int
        }

        struct TrailFix: Codable, Equatable, Sendable {
            var tMs: Int
            var lat: Double
            var lon: Double
            var accuracyM: Double
            var speedMps: Double?
        }

        mutating func attach(_ fixes: [LocationObservation], moment: Date, until latest: Date) {
            if let combined = ConnectionLocationQuality.fused(fixes, around: moment, until: latest) {
                fused = Fused(lat: combined.latitude, lon: combined.longitude,
                              radiusM: LocationObservation.rounded(combined.radiusMeters, places: 2),
                              fixCount: combined.fixCount, spanMs: combined.spanMs)
            }
            let nearest = fixes
                .sorted { abs($0.observedAt.timeIntervalSince(moment)) < abs($1.observedAt.timeIntervalSince(moment)) }
                .prefix(Self.maximumTrail)
                .sorted { $0.observedAt < $1.observedAt }
            trail = nearest.isEmpty ? nil : nearest.map {
                TrailFix(tMs: SensorClock.milliseconds($0.observedAt.timeIntervalSince(moment)), lat: $0.latitude, lon: $0.longitude,
                         accuracyM: LocationObservation.rounded($0.horizontalAccuracyMeters, places: 2),
                         speedMps: $0.speedMetersPerSecond.map { LocationObservation.rounded($0, places: 2) })
            }
        }

        init(_ fix: LocationObservation, moment: Date, updatesSeen: Int) {
            lat = fix.latitude
            lon = fix.longitude
            horizontalAccuracyM = LocationObservation.rounded(fix.horizontalAccuracyMeters, places: 2)
            altitudeMslM = fix.altitudeMeters.map { LocationObservation.rounded($0, places: 2) }
            ellipsoidalAltitudeM = fix.ellipsoidalAltitudeMeters.map { LocationObservation.rounded($0, places: 2) }
            verticalAccuracyM = fix.verticalAccuracyMeters.map { LocationObservation.rounded($0, places: 2) }
            speedMps = fix.speedMetersPerSecond.map { LocationObservation.rounded($0, places: 2) }
            speedAccuracyMps = fix.speedAccuracyMetersPerSecond.map { LocationObservation.rounded($0, places: 2) }
            courseDeg = fix.courseDegrees.map { LocationObservation.rounded($0, places: 1) }
            courseAccuracyDeg = fix.courseAccuracyDegrees.map { LocationObservation.rounded($0, places: 1) }
            floor = fix.floorLevel
            fullAccuracy = fix.isFullAccuracy
            observedAt = fix.observedAt
            ageAtMomentMs = SensorClock.milliseconds(moment.timeIntervalSince(fix.observedAt))
            simulated = fix.isSimulatedBySoftware
            externalAccessory = fix.isProducedByAccessory
            self.updatesSeen = updatesSeen
        }
    }

    struct Barometer: Codable, Equatable, Sendable {
        static let maximumSamples = 12

        var pressureKpa: Double?
        var absoluteAltitudeM: Double?
        var absoluteAccuracyM: Double?
        var absolutePrecisionM: Double?
        var relativeAltitudeM: Double?
        var observedAt: Date
        var samplesCollected: Int
        /// The individual short-window readings nearest the moment.
        var samples: [Sample]

        struct Sample: Codable, Equatable, Sendable {
            var tMs: Int
            var altitudeM: Double?
            var accuracyM: Double?
            var pressureKpa: Double?
            var relativeAltitudeM: Double?
        }

        init?(
            _ reading: AltitudeObservation?,
            absolute: [AbsoluteAltitudeSample],
            relative: [RelativeAltitudeSample],
            moment: Date
        ) {
            guard let reading else { return nil }
            pressureKpa = reading.pressureKPa.map { LocationObservation.rounded($0, places: 3) }
            absoluteAltitudeM = reading.absoluteAltitudeMeters.map { LocationObservation.rounded($0, places: 2) }
            absoluteAccuracyM = reading.accuracyMeters.map { LocationObservation.rounded($0, places: 2) }
            absolutePrecisionM = reading.precisionMeters.map { LocationObservation.rounded($0, places: 2) }
            relativeAltitudeM = reading.relativeAltitudeMeters.map { LocationObservation.rounded($0, places: 2) }
            observedAt = reading.observedAt
            samplesCollected = absolute.count + relative.count
            let t = { (date: Date) in SensorClock.milliseconds(date.timeIntervalSince(moment)) }
            let merged: [Sample] = absolute.filter { $0.altitudeMeters.isFinite && $0.accuracyMeters.isFinite }.map {
                Sample(tMs: t($0.observedAt), altitudeM: LocationObservation.rounded($0.altitudeMeters, places: 2),
                       accuracyM: LocationObservation.rounded($0.accuracyMeters, places: 2))
            } + relative.filter { $0.pressureKPa.isFinite && $0.relativeAltitudeMeters.isFinite }.map {
                Sample(tMs: t($0.observedAt), pressureKpa: LocationObservation.rounded($0.pressureKPa, places: 3),
                       relativeAltitudeM: LocationObservation.rounded($0.relativeAltitudeMeters, places: 2))
            }
            samples = merged
                .sorted { abs($0.tMs) < abs($1.tMs) }
                .prefix(Self.maximumSamples)
                .sorted { $0.tMs < $1.tMs }
        }
    }

    struct Heading: Codable, Equatable, Sendable {
        var magneticDeg: Double?
        var trueDeg: Double?
        var accuracyDeg: Double?
        /// Raw geomagnetic vector (µT) reported with the heading, and its magnitude.
        var magneticFieldUt: [Double]?
        var magneticFieldMagnitudeUt: Double?
        /// Core Motion's calibrated field and its calibration level near the moment.
        var calibratedMagneticFieldUt: [Double]?
        var magneticCalibration: String?
        var observedAt: Date?

        init?(_ heading: HeadingSample?, motion: [MotionSample], momentUptime: TimeInterval) {
            let nearest = motion.min { abs($0.uptime - momentUptime) < abs($1.uptime - momentUptime) }
            guard heading != nil || nearest?.magneticAccuracy != nil else { return nil }
            let round = { (value: Double) in LocationObservation.rounded(value, places: 2) }
            magneticDeg = heading?.magneticHeading.map { LocationObservation.rounded($0, places: 1) }
            trueDeg = heading?.trueHeading.map { LocationObservation.rounded($0, places: 1) }
            accuracyDeg = heading?.headingAccuracy.map { LocationObservation.rounded($0, places: 1) }
            magneticFieldUt = heading?.field.map { $0.map(round) }
            magneticFieldMagnitudeUt = heading?.field.map { round($0.reduce(0) { $0 + $1 * $1 }.squareRoot()) }
            calibratedMagneticFieldUt = nearest?.magneticField.map { $0.map(round) }
            magneticCalibration = nearest?.magneticAccuracy.map(Self.calibrationName)
            observedAt = heading?.observedAt
        }

        static func calibrationName(_ raw: Int) -> String {
            switch raw {
            case 0: "low"
            case 1: "medium"
            case 2: "high"
            default: "uncalibrated"
            }
        }
    }

    /// The system's activity classification — supplemental, not the canonical movement signal.
    struct Activity: Codable, Equatable, Sendable {
        var activity: String
        var confidence: String
        var startedAt: Date
    }

    struct Pedometer: Codable, Equatable, Sendable {
        var windowS: Int
        var steps: Int?
        var distanceM: Double?
        var floorsAscended: Int?
        var floorsDescended: Int?
        var currentCadenceSps: Double?
        var currentPaceSpm: Double?
    }

    struct UWB: Codable, Equatable, Sendable {
        var distanceM: Double?
        var direction: [Double]?
        var horizontalAngleRad: Double?
        var verticalDirection: String?
        var observedAt: Date
    }

    /// For sensor-quality analysis and normalization only — never consumer-facing profiling.
    struct Device: Codable, Equatable, Sendable {
        var batteryPercent: Int?
        var lowPowerMode: Bool
        var thermalState: String
        var deviceModel: String
        var osVersion: String
        /// Screen brightness × 1000 (the legacy `lux_level`) — not ambient light.
        var screenBrightnessProxy: Double?
        var capabilities: Capabilities
        /// Where audio was routed (e.g. "Speaker", "BluetoothA2DPOutput"): headphones or a car
        /// take over the speaker and explain ultrasonic misses.
        var audioOutput: String? = nil
        var audioInput: String? = nil
        var charging: Bool? = nil

        struct Capabilities: Codable, Equatable, Sendable {
            var barometer: Bool
            var absoluteAltitude: Bool
            var deviceMotion: Bool
            var magnetometer: Bool
            var uwb: Bool
            var preciseLocationAuthorized: Bool
        }
    }
}

// MARK: - Assembly

extension ConnectionSensorObservation {
    /// - Parameter includeLocation: false when Location snap is off; then no location-derived
    ///   value (coordinate, speed, course, true heading) is included.
    init(
        method: String,
        snapshot: ConnectionCaptureSession.Snapshot,
        includeLocation: Bool,
        bluetooth: BluetoothTrace? = nil,
        acoustic: AcousticTrace? = nil,
        device: Device?
    ) {
        let moment = snapshot.moment
        self.init(
            method: method,
            capturedAt: snapshot.startedAt,
            connectionMoment: moment,
            captureDurationMs: snapshot.startedAt.map { SensorClock.milliseconds(snapshot.finishedAt.timeIntervalSince($0)) },
            location: includeLocation
                ? snapshot.location.map {
                    var location = Location($0, moment: moment, updatesSeen: snapshot.locationUpdates)
                    location.attach(snapshot.locationFixes, moment: moment, until: snapshot.finishedAt)
                    return location
                }
                : nil,
            barometer: Barometer(snapshot.altitude, absolute: snapshot.absoluteAltitudeSamples,
                                 relative: snapshot.relativeAltitudeSamples, moment: moment),
            motion: MotionObservation.window(snapshot.motionSamples, momentUptime: snapshot.momentUptime),
            heading: Heading(includeLocation ? snapshot.heading : nil, motion: snapshot.motionSamples,
                             momentUptime: snapshot.momentUptime),
            activity: snapshot.activity,
            pedometer: snapshot.pedometer,
            bluetooth: BluetoothObservation(bluetooth, momentUptime: snapshot.momentUptime),
            acoustic: AcousticObservation(acoustic, momentUptime: snapshot.momentUptime),
            uwb: nil,
            device: device
        )
    }

    /// The `sensor_observation` request value (snake_case JSON). Bounded: if it would exceed
    /// `maximumPayloadBytes`, motion samples are dropped (their summary stays).
    var payload: [String: Any]? {
        var stamped = self
        stamped.clock = Clock(sentAt: .now, timeZoneOffsetS: TimeZone.current.secondsFromGMT())
        for candidate in [stamped, stamped.withoutMotionSamples] {
            guard let data = try? Self.encoder.encode(candidate), data.count <= Self.maximumPayloadBytes else { continue }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    private var withoutMotionSamples: ConnectionSensorObservation {
        var copy = self
        copy.motion?.samples = []
        return copy
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    /// Allowlisted aggregates for `connection_flow_events.capture_quality`: accuracy, latency and
    /// signal-quality numbers only — no coordinates, tokens or identifiers.
    var captureQuality: [String: TelemetryValue] {
        var out: [String: TelemetryValue] = [
            "location_available": .bool(location != nil),
            "barometer_available": .bool(barometer?.absoluteAltitudeM != nil),
            "motion_available": .bool(motion != nil),
            "heading_available": .bool(heading != nil),
            "uwb_available": .bool(device?.capabilities.uwb ?? false),
            "activity_available": .bool(activity != nil),
            "pedometer_available": .bool(pedometer != nil),
            "connection_method": .string(method),
            "location_accuracy_bucket": .string(location.map { ConnectionLocationQuality.tier($0.horizontalAccuracyM) } ?? "none")
        ]
        if let location {
            out["location_accuracy_m"] = .double(location.horizontalAccuracyM)
            out["location_full_accuracy"] = .bool(location.fullAccuracy)
            out["location_update_count"] = .int(location.updatesSeen)
            out["floor_available"] = .bool(location.floor != nil)
            if let fused = location.fused {
                out["location_fused_fix_count"] = .int(fused.fixCount)
                out["location_fused_radius_m"] = .double(fused.radiusM)
            }
        }
        if let captureDurationMs {
            out["capture_duration_ms"] = .int(max(0, captureDurationMs))
            if location != nil { out["location_capture_ms"] = .int(max(0, captureDurationMs)) }
        }
        if let accuracy = barometer?.absoluteAccuracyM { out["barometer_accuracy_m"] = .double(accuracy) }
        if let motion { out["motion_sample_count"] = .int(motion.sampleCount) }
        if let peers = bluetooth?.peers {
            out["ble_peer_count"] = .int(peers.count)
            let rssi = peers.flatMap(\.rssiSamplesDbm).sorted()
            out["ble_rssi_sample_count"] = .int(rssi.count)
            if let median = BluetoothObservation.median(rssi) { out["ble_rssi_median_dbm"] = .double(median) }
            if let discovery = peers.compactMap(\.timeToDiscoveryMs).min() { out["ble_discovery_ms"] = .int(discovery) }
            if let read = peers.compactMap(\.gattReadLatencyMs).min() { out["ble_gatt_read_ms"] = .int(read) }
        }
        if let acoustic {
            out["ultrasonic_peer_count"] = .int(acoustic.peers.count)
            if let snr = acoustic.peers.compactMap(\.signalToNoiseRatioDb).max() { out["ultrasonic_snr_db"] = .double(snr) }
            if let ratio = acoustic.peers.compactMap(\.peakToSecondPeakRatio).max() { out["ultrasonic_peak_ratio"] = .double(ratio) }
            if let decode = acoustic.decodeDurationMs { out["ultrasonic_decode_ms"] = .int(decode) }
        }
        out["sensor_failure"] = .string(sensorFailure)
        return out
    }

    /// The first missing factor, coarse enough for funnel analysis.
    private var sensorFailure: String {
        if location == nil { return "location_unavailable" }
        if let bluetooth, bluetooth.peers.isEmpty { return "bluetooth_no_peer" }
        if let acoustic, acoustic.peers.isEmpty { return "ultrasonic_no_peer" }
        if motion == nil { return "motion_unavailable" }
        return "none"
    }

    /// DEBUG `-connection-log` summary of the non-location sensors (no coordinates).
    @MainActor
    func logDiagnostics() {
        #if DEBUG
        guard DebugLaunch.has("-connection-log") else { return }
        var lines = ["method=\(method) schema=\(schemaVersion) duration_ms=\(captureDurationMs.map(String.init) ?? "–")"]
        if let barometer {
            lines.append("barometer: samples=\(barometer.samplesCollected) pressure_kpa=\(barometer.pressureKpa.map { "\($0)" } ?? "–") accuracy_m=\(barometer.absoluteAccuracyM.map { "\($0)" } ?? "–")")
        }
        if let motion {
            lines.append("motion: samples=\(motion.sampleCount) window_ms=\(motion.windowMs) peak_accel_g=\(motion.summary.peakAcceleration)")
        }
        if let heading {
            lines.append("heading: magnetic=\(heading.magneticDeg.map { "\($0)" } ?? "–") accuracy=\(heading.accuracyDeg.map { "\($0)" } ?? "–") calibration=\(heading.magneticCalibration ?? "–")")
        }
        for (index, peer) in (bluetooth?.peers ?? []).enumerated() {
            lines.append("ble peer \(index + 1): rssi_median=\(peer.rssiMedianDbm.map { "\($0)" } ?? "–") samples=\(peer.rssiSamplesDbm.count) discovery_ms=\(peer.timeToDiscoveryMs.map(String.init) ?? "–") gatt_read_ms=\(peer.gattReadLatencyMs.map(String.init) ?? "–")")
        }
        if let acoustic {
            lines.append("ultrasonic: attempts=\(acoustic.decodeAttemptCount.map(String.init) ?? "–") failed=\(acoustic.failedDecodeCount.map(String.init) ?? "–") decode_ms=\(acoustic.decodeDurationMs.map(String.init) ?? "–")")
            for (index, peer) in acoustic.peers.enumerated() {
                lines.append("  peer \(index + 1): snr_db=\(peer.signalToNoiseRatioDb.map { "\($0)" } ?? "–") peak_ratio=\(peer.peakToSecondPeakRatio.map { "\($0)" } ?? "–") first_detected_ms=\(peer.firstDetectedMs.map(String.init) ?? "–")")
            }
        }
        if let device {
            lines.append("device: thermal=\(device.thermalState) low_power=\(device.lowPowerMode) model=\(device.deviceModel)")
        }
        ConnectionDebugLog.shared.note("[sensors] \(method)", lines.joined(separator: "\n"))
        #endif
    }
}

// MARK: - Device context, activity, pedometer

extension ConnectionSensorObservation.Device {
    @MainActor
    static func current(screenBrightnessProxy: Double?, preciseLocationAuthorized: Bool) -> Self {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let batteryState = device.batteryState
        device.isBatteryMonitoringEnabled = wasMonitoring
        let motion = CMMotionManager()
        let route = AVAudioSession.sharedInstance().currentRoute
        return Self(
            batteryPercent: level.isFinite && level >= 0 ? min(100, Int((level * 100).rounded())) : nil,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalName(ProcessInfo.processInfo.thermalState),
            deviceModel: modelIdentifier(),
            osVersion: device.systemVersion,
            screenBrightnessProxy: screenBrightnessProxy,
            capabilities: Capabilities(
                barometer: CMAltimeter.isRelativeAltitudeAvailable(),
                absoluteAltitude: CMAltimeter.isAbsoluteAltitudeAvailable(),
                deviceMotion: motion.isDeviceMotionAvailable,
                magnetometer: motion.isMagnetometerAvailable,
                uwb: NISession.deviceCapabilities.supportsPreciseDistanceMeasurement,
                preciseLocationAuthorized: preciseLocationAuthorized
            ),
            audioOutput: route.outputs.first?.portType.rawValue,
            audioInput: route.inputs.first?.portType.rawValue,
            charging: batteryState == .unknown ? nil : (batteryState == .charging || batteryState == .full)
        )
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// e.g. "iPhone16,2" (the hardware model, not a user or device identifier).
    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Short, permission-respecting reads of system motion context at the connection moment. Never
/// prompts: each returns nil unless Motion & Fitness access was already granted.
enum MotionContextSampler {
    static let timeout: Duration = .milliseconds(500)
    static let activityLookback: TimeInterval = 120
    static let pedometerWindow: TimeInterval = 60

    /// Nonisolated with `@Sendable` handlers on purpose: Core Motion calls the pedometer handler
    /// on its own serial queue (`CMPedometerUpdateQueue`). A handler written in main-actor code
    /// inherits main-actor isolation under Swift 6, and its runtime isolation check traps the
    /// app the moment the result arrives (the 1.1.0 (481) QR / Tap to Connect crash).
    static func activity(at moment: Date) async -> ConnectionSensorObservation.Activity? {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return nil }
        let manager = CMMotionActivityManager()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let result: ConnectionSensorObservation.Activity? = await firstResult { deliver in
            manager.queryActivityStarting(
                from: moment.addingTimeInterval(-activityLookback), to: moment, to: queue
            ) { @Sendable activities, _ in
                deliver(activities?.last.map(Self.activityObservation))
            }
        }
        withExtendedLifetime(manager) {}
        return result
    }

    static func pedometer(at moment: Date) async -> ConnectionSensorObservation.Pedometer? {
        guard CMPedometer.isStepCountingAvailable(), CMPedometer.authorizationStatus() == .authorized else { return nil }
        let pedometer = CMPedometer()
        let result: ConnectionSensorObservation.Pedometer? = await firstResult { deliver in
            pedometer.queryPedometerData(from: moment.addingTimeInterval(-pedometerWindow), to: moment) { @Sendable data, _ in
                deliver(data.map(Self.pedometerObservation))
            }
        }
        withExtendedLifetime(pedometer) {}
        return result
    }

    static func activityObservation(_ activity: CMMotionActivity) -> ConnectionSensorObservation.Activity {
        let kind = activity.automotive ? "automotive"
            : activity.cycling ? "cycling"
            : activity.running ? "running"
            : activity.walking ? "walking"
            : activity.stationary ? "stationary"
            : "unknown"
        let confidence = switch activity.confidence {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        @unknown default: "unknown"
        }
        return .init(activity: kind, confidence: confidence, startedAt: activity.startDate)
    }

    static func pedometerObservation(_ data: CMPedometerData) -> ConnectionSensorObservation.Pedometer {
        .init(
            windowS: Int(pedometerWindow),
            steps: data.numberOfSteps.intValue,
            distanceM: data.distance.map { LocationObservation.rounded($0.doubleValue, places: 1) },
            floorsAscended: data.floorsAscended?.intValue,
            floorsDescended: data.floorsDescended?.intValue,
            currentCadenceSps: data.currentCadence.map { LocationObservation.rounded($0.doubleValue, places: 2) },
            currentPaceSpm: data.currentPace.map { LocationObservation.rounded($0.doubleValue, places: 3) }
        )
    }

    /// The first value `body` delivers, or nil after `timeout`.
    private static func firstResult<T: Sendable>(_ body: (@escaping @Sendable (T?) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            body { once.resume($0) }
            Task {
                try? await Task.sleep(for: Self.timeout)
                once.resume(nil)
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T?, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
