import CoreLocation
import Foundation
import Testing
@testable import Click

@Suite("Connection sensor observation")
struct ConnectionSensorObservationTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let moment: TimeInterval = 5_000

    // MARK: Location velocity and provenance

    @Test("Negative speed and course are unavailable, never substituted")
    func invalidVelocity() throws {
        let now = Date()
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.34), altitude: 50,
            horizontalAccuracy: 5, verticalAccuracy: 8, course: -1, speed: -1, timestamp: now
        )
        let fix = try #require(LocationObservation(location, isFullAccuracy: true, maximumAge: 10, now: now))
        #expect(fix.speedMetersPerSecond == nil)
        #expect(fix.courseDegrees == nil)
        #expect(fix.qualityColumns["gps_speed_mps"] == nil)
        #expect(fix.qualityColumns["gps_course_deg"] == nil)
    }

    @Test("Valid velocity and a simulated source are recorded as measured")
    func velocityAndProvenance() {
        let fix = LocationObservation(
            latitude: 47.61, longitude: -122.34, horizontalAccuracyMeters: 4.3, verticalAccuracyMeters: 7.2,
            altitudeMeters: 51.4, ellipsoidalAltitudeMeters: 69.1, observedAt: t0, floorLevel: nil,
            isFullAccuracy: true, isSimulatedBySoftware: true, isProducedByAccessory: false,
            speedMetersPerSecond: 0.2, speedAccuracyMetersPerSecond: 0.7, courseDegrees: 91.25, courseAccuracyDegrees: 12
        )
        let columns = fix.qualityColumns
        #expect(columns["gps_speed_mps"] as? Double == 0.2)
        #expect(columns["gps_speed_accuracy_mps"] as? Double == 0.7)
        #expect(columns["gps_course_deg"] as? Double == 91.3)
        #expect(columns["gps_simulated"] as? Bool == true)
        #expect(columns["gps_external_accessory"] as? Bool == false)
    }

    // MARK: Motion

    private func motion(at uptime: TimeInterval, acceleration: Double = 0, rotation: Double = 0) -> MotionSample {
        MotionSample(
            uptime: uptime, gravity: [0, -1, 0], userAcceleration: [acceleration, 0, 0],
            rotationRate: [0, rotation, 0], attitudeQuaternion: [0, 0, 0, 1],
            magneticField: [19.2, -38.7, 12.3], magneticAccuracy: 2
        )
    }

    @Test("The motion window keeps only samples around the moment, downsampled to 25 Hz")
    func motionWindow() throws {
        // 100 Hz for 4 s, centred on the moment.
        let samples = (0..<400).map { motion(at: moment - 2 + Double($0) / 100) }
        let window = try #require(MotionObservation.window(samples, momentUptime: moment))
        #expect(window.samples.allSatisfy { (-1000...1000).contains($0.tMs) })
        #expect(window.sampleCount <= 51)
        #expect(window.sampleCount >= 45)
        #expect(window.windowStartMs >= -1000)
        #expect(window.samples.first?.magneticField == [19.2, -38.7, 12.3])
    }

    @Test("Motion summary statistics describe the gesture")
    func motionSummary() throws {
        let samples = [motion(at: moment - 0.08, acceleration: 0.1),
                       motion(at: moment - 0.04, acceleration: 0.3, rotation: 2),
                       motion(at: moment, acceleration: -0.1)]
        let summary = try #require(MotionObservation.window(samples, momentUptime: moment)).summary
        #expect(summary.accelerationMax[0] == 0.3)
        #expect(summary.accelerationMin[0] == -0.1)
        #expect(abs(summary.accelerationMean[0] - 0.1) < 0.0001)
        #expect(summary.peakAcceleration == 0.3)
        #expect(summary.peakRotation == 2)
        #expect(summary.startQuaternion == [0, 0, 0, 1])
    }

    @Test("No samples (or only non-finite ones) means no motion observation")
    func missingMotion() {
        #expect(MotionObservation.window([], momentUptime: moment) == nil)
        let broken = MotionSample(uptime: moment, gravity: [.nan, 0, 0], userAcceleration: [0, 0, 0],
                                  rotationRate: [0, 0, 0], attitudeQuaternion: [0, 0, 0, 1])
        #expect(MotionObservation.window([broken], momentUptime: moment) == nil)
        #expect(MotionObservation.window([motion(at: moment - 5)], momentUptime: moment) == nil)
    }

    // MARK: Bluetooth

    @Test("RSSI series ignores unavailable readings and is bounded")
    func rssiSeries() {
        var peer = BluetoothPeerTrace(firstSeen: moment - 4)
        peer.record(rssi: 127)
        for value in [-57, -59, -58, -61, -60] { peer.record(rssi: value) }
        #expect(peer.rssiSamples == [-57, -59, -58, -61, -60])
        for _ in 0..<100 { peer.record(rssi: -50) }
        #expect(peer.rssiSamples.count == BluetoothPeerTrace.maximumRSSISamples)
    }

    @Test("Peers stay separate; median, latencies and missing TX power are handled")
    func bluetoothPeers() throws {
        var first = BluetoothPeerTrace(firstSeen: moment - 4.6)
        for value in [-57, -59, -58, -61] { first.record(rssi: value) }
        first.connectStarted = moment - 4.6
        first.connected = moment - 4.513
        first.characteristicDiscovered = moment - 4.4
        first.tokenRead = moment - 4.276
        first.token = "1234"
        var second = BluetoothPeerTrace(firstSeen: moment - 3)
        second.record(rssi: -70)
        second.txPower = -12
        second.token = "5678"
        let unread = BluetoothPeerTrace(firstSeen: moment - 2)
        let observation = try #require(BluetoothObservation(
            BluetoothTrace(scanStarted: moment - 5, peers: [first, second, unread]), momentUptime: moment
        ))
        #expect(observation.peers.map(\.token) == ["1234", "5678"])
        let a = observation.peers[0]
        #expect(a.rssiMedianDbm == -58.5)
        #expect(a.rssiMinDbm == -61)
        #expect(a.txPowerDbm == nil)
        #expect(a.pathLossDb == nil)
        #expect(a.timeToDiscoveryMs == 400)
        #expect(a.connectionLatencyMs == 87)
        #expect(a.gattReadLatencyMs == 124)
        #expect(a.firstSeenMs == -4600)
        let b = observation.peers[1]
        #expect(b.rssiSamplesDbm == [-70])
        #expect(b.pathLossDb == 58)
    }

    // MARK: Ultrasonic

    private func capture(token: String, gain: Double = 0.05) -> [Int16] {
        var generator = SeededNoise(seed: 7)
        var samples = [Double](repeating: 0, count: ProximityCodec.sampleRate * 2)
        let start = ProximityCodec.sampleRate / 4
        for (index, value) in ProximityCodec.handshakePCM(token: token).enumerated() where start + index < samples.count {
            samples[start + index] = Double(value) / 32768 * gain
        }
        return samples.map { Int16(max(min(($0 + Double.random(in: -0.002...0.002, using: &generator)) * 32767, 32767), -32768)) }
    }

    @Test("A decoded chirp keeps its signal and decoder quality")
    func decodeMetrics() throws {
        let decode = ProximityCodec.decodeWithMetrics(capture(token: "4826"))
        #expect(decode.tokens == ["4826"])
        #expect(decode.tokens == ProximityCodec.decodeAllTokens(capture(token: "4826")))
        let detection = try #require(decode.detections.first)
        #expect(detection.peakToSecondPeakRatio >= 4)
        #expect(detection.chirpFrames >= 11)
        #expect(decode.attempts >= 1)
        let observation = try #require(AcousticObservation(
            AcousticTrace(recordStarted: moment - 3, decode: decode), momentUptime: moment
        ))
        let peer = try #require(observation.peers.first)
        #expect(peer.token == "4826")
        #expect((peer.signalToNoiseRatioDb ?? 0) > 10)
        #expect(peer.firstDetectedMs.map { $0 > -3000 && $0 < -2000 } == true)
    }

    @Test("Noise decodes nothing but still reports the capture")
    func failedDecode() {
        var generator = SeededNoise(seed: 3)
        let noise = (0..<ProximityCodec.sampleRate).map { _ in Int16.random(in: -400...400, using: &generator) }
        let decode = ProximityCodec.decodeWithMetrics(noise)
        #expect(decode.detections.isEmpty)
        #expect(decode.samplesAnalyzed == ProximityCodec.sampleRate)
        #expect(decode.captureRMS > 0)
    }

    @Test("Non-finite decoder values are dropped and no audio is ever serialized")
    func acousticSafety() throws {
        #expect(AcousticObservation.metric(.infinity, places: 2) == nil)
        #expect(AcousticObservation.metric(.nan, places: 2) == nil)
        let observation = ConnectionSensorObservation(
            method: "tap", capturedAt: t0, connectionMoment: t0,
            acoustic: AcousticObservation(
                AcousticTrace(recordStarted: moment - 3, decode: ProximityCodec.decodeWithMetrics(capture(token: "4826"))),
                momentUptime: moment
            )
        )
        let acoustic = try #require(observation.payload?["acoustic"] as? [String: Any])
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: acoustic), as: UTF8.self)
        #expect(!serialized.contains("\"samples\""))
        #expect(!serialized.contains("audio"))
        #expect(serialized.count < 2_000)
    }

    // MARK: Barometer

    @Test("Unsupported altimeter yields no barometer; samples are bounded and keep pressure")
    func barometer() throws {
        #expect(ConnectionSensorObservation.Barometer(nil, absolute: [], relative: [], moment: t0) == nil)
        let absolute = (0..<20).map {
            AbsoluteAltitudeSample(altitudeMeters: 50 + Double($0) / 10, accuracyMeters: 1.5, precisionMeters: 0.3,
                                   observedAt: t0.addingTimeInterval(-Double($0) / 4))
        }
        let relative = [RelativeAltitudeSample(relativeAltitudeMeters: 0.1, pressureKPa: 100.81, observedAt: t0)]
        let reading = AltitudeStabilizer.stabilized(absolute: absolute, relative: relative, around: t0, until: t0)
        let barometer = try #require(ConnectionSensorObservation.Barometer(reading, absolute: absolute, relative: relative, moment: t0))
        #expect(barometer.samplesCollected == 21)
        #expect(barometer.samples.count == ConnectionSensorObservation.Barometer.maximumSamples)
        #expect(barometer.pressureKpa == 100.81)
        #expect(barometer.samples.contains { $0.pressureKpa == 100.81 })
    }

    // MARK: Payload

    private func snapshot(location: Bool) -> ConnectionCaptureSession.Snapshot {
        var snapshot = ConnectionCaptureSession.Snapshot()
        snapshot.moment = t0
        snapshot.momentUptime = moment
        snapshot.startedAt = t0.addingTimeInterval(-3)
        snapshot.finishedAt = t0.addingTimeInterval(0.2)
        snapshot.location = location ? LocationObservation(
            latitude: 47.61, longitude: -122.34, horizontalAccuracyMeters: 4.8, verticalAccuracyMeters: nil,
            altitudeMeters: nil, ellipsoidalAltitudeMeters: nil, observedAt: t0.addingTimeInterval(-0.22),
            floorLevel: 3, isFullAccuracy: true, isSimulatedBySoftware: false, isProducedByAccessory: false
        ) : nil
        snapshot.locationUpdates = 7
        snapshot.motionSamples = (0..<50).map { motion(at: moment - 1 + Double($0) / 25) }
        return snapshot
    }

    @Test("The wire payload is versioned snake_case aligned on the connection moment")
    func payload() throws {
        let observation = ConnectionSensorObservation(method: "qr", snapshot: snapshot(location: true), includeLocation: true, device: nil)
        let payload = try #require(observation.payload)
        #expect(payload["schema_version"] as? Int == 2)
        #expect(payload["connection_moment"] is String)
        #expect(payload["capture_duration_ms"] as? Int == 3200)
        let location = try #require(payload["location"] as? [String: Any])
        #expect(location["horizontal_accuracy_m"] as? Double == 4.8)
        #expect(location["age_at_moment_ms"] as? Int == 220)
        #expect(location["floor"] as? Int == 3)
        #expect(location["updates_seen"] as? Int == 7)
        let motion = try #require(payload["motion"] as? [String: Any])
        let first = try #require((motion["samples"] as? [[String: Any]])?.first)
        #expect(first["t_ms"] is Int)
        #expect(first["attitude_quaternion"] as? [Double] == [0, 0, 0, 1])
        #expect(payload["uwb"] == nil)
    }

    @Test("Location-derived values are left out when Location snap is off")
    func locationGate() {
        let observation = ConnectionSensorObservation(method: "tap", snapshot: snapshot(location: true), includeLocation: false, device: nil)
        #expect(observation.location == nil)
        #expect(observation.payload?["location"] == nil)
    }

    @Test("An oversized payload drops motion samples but keeps their summary")
    func payloadBound() throws {
        var observation = ConnectionSensorObservation(method: "tap", snapshot: snapshot(location: false), includeLocation: false, device: nil)
        let sample = try #require(observation.motion?.samples.first)
        observation.motion?.samples = Array(repeating: sample, count: 2_000)
        let motion = try #require(observation.payload?["motion"] as? [String: Any])
        #expect((motion["samples"] as? [Any])?.isEmpty == true)
        #expect(motion["summary"] != nil)
    }

    @Test("Capture quality carries aggregates only — no coordinates or tokens")
    func captureQuality() {
        var observation = ConnectionSensorObservation(method: "tap", snapshot: snapshot(location: true), includeLocation: true, device: nil)
        var peer = BluetoothPeerTrace(firstSeen: moment - 4)
        peer.record(rssi: -56)
        peer.token = "1234"
        observation.bluetooth = BluetoothObservation(BluetoothTrace(scanStarted: moment - 4.4, peers: [peer]), momentUptime: moment)
        let quality = observation.captureQuality
        #expect(quality["location_accuracy_m"] == .double(4.8))
        #expect(quality["location_accuracy_bucket"] == .string("excellent"))
        #expect(quality["ble_rssi_median_dbm"] == .double(-56))
        #expect(quality["ble_discovery_ms"] == .int(400))
        #expect(quality["motion_available"] == .bool(true))
        for forbidden in ["lat", "lon", "latitude", "longitude", "token"] {
            #expect(quality[forbidden] == nil)
        }
        let body = ConnectionFlowTelemetry(queue: TelemetryQueue(suiteName: "capture-quality-test"), sample: { 0 })
            .payload(.matched, captureQuality: quality)
        guard case .object(let nested)? = body?["capture_quality"] else {
            Issue.record("capture_quality missing")
            return
        }
        #expect(nested["ble_peer_count"] == .int(1))
    }
}

/// Deterministic noise for reproducible decoder tests.
private struct SeededNoise: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
