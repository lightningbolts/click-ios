import CoreMotion
import Foundation

/// One `CMDeviceMotion` reading reduced to scalars, stamped on the monotonic sensor clock.
struct MotionSample: Equatable, Sendable {
    /// Seconds since boot (`CMLogItem.timestamp`).
    let uptime: TimeInterval
    /// g; gravity and user acceleration are separated by Core Motion's own fusion.
    let gravity: [Double]
    let userAcceleration: [Double]
    /// rad/s.
    let rotationRate: [Double]
    /// Canonical orientation, [x, y, z, w]; pitch/roll/yaw can be derived later.
    let attitudeQuaternion: [Double]
    /// Calibrated field (µT); nil while Core Motion reports it uncalibrated.
    let magneticField: [Double]?
    /// `CMMagneticFieldCalibrationAccuracy` raw value (-1 uncalibrated … 2 high).
    let magneticAccuracy: Int?

    init(
        uptime: TimeInterval,
        gravity: [Double],
        userAcceleration: [Double],
        rotationRate: [Double],
        attitudeQuaternion: [Double],
        magneticField: [Double]? = nil,
        magneticAccuracy: Int? = nil
    ) {
        self.uptime = uptime
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.attitudeQuaternion = attitudeQuaternion
        self.magneticField = magneticField
        self.magneticAccuracy = magneticAccuracy
    }

    init(_ motion: CMDeviceMotion) {
        let field = motion.magneticField
        let calibrated = field.accuracy != .uncalibrated
        self.init(
            uptime: motion.timestamp,
            gravity: [motion.gravity.x, motion.gravity.y, motion.gravity.z],
            userAcceleration: [motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z],
            rotationRate: [motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z],
            attitudeQuaternion: [motion.attitude.quaternion.x, motion.attitude.quaternion.y,
                                 motion.attitude.quaternion.z, motion.attitude.quaternion.w],
            magneticField: calibrated ? [field.field.x, field.field.y, field.field.z] : nil,
            magneticAccuracy: Int(field.accuracy.rawValue)
        )
    }

    var isFinite: Bool {
        (gravity + userAcceleration + rotationRate + attitudeQuaternion + (magneticField ?? [])).allSatisfy(\.isFinite)
    }
}

/// A short device-motion window around the connection moment: a bounded, downsampled series
/// (so the shape of the gesture survives) plus summary statistics. `motion_variance` remains a
/// separate derived compatibility field.
struct MotionObservation: Codable, Equatable, Sendable {
    /// Window around the connection moment, configurable per capture.
    static let defaultBefore: TimeInterval = 1
    static let defaultAfter: TimeInterval = 1
    static let sampleRateHz = 25

    var sampleRateHz: Int
    /// First and last kept sample, relative to the connection moment.
    var windowStartMs: Int
    var windowMs: Int
    var sampleCount: Int
    var samples: [Sample]
    var summary: Summary

    struct Sample: Codable, Equatable, Sendable {
        var tMs: Int
        var gravity: [Double]
        var userAcceleration: [Double]
        var rotationRate: [Double]
        var attitudeQuaternion: [Double]
        var magneticField: [Double]?
        var magneticAccuracy: Int?
    }

    struct Summary: Codable, Equatable, Sendable {
        var accelerationMean: [Double]
        var accelerationStd: [Double]
        var accelerationMin: [Double]
        var accelerationMax: [Double]
        var rotationMean: [Double]
        var rotationStd: [Double]
        var rotationMin: [Double]
        var rotationMax: [Double]
        /// Magnitude statistics of user acceleration (g) and rotation rate (rad/s).
        var rmsAcceleration: Double
        var rmsRotation: Double
        var peakAcceleration: Double
        var peakRotation: Double
        var startQuaternion: [Double]
        var endQuaternion: [Double]
    }

    /// Keeps finite samples within [moment − before, moment + after], downsampled to at most
    /// `rateHz`. Nil when no sample falls in the window (e.g. device motion unavailable).
    static func window(
        _ samples: [MotionSample],
        momentUptime: TimeInterval,
        before: TimeInterval = defaultBefore,
        after: TimeInterval = defaultAfter,
        rateHz: Int = sampleRateHz
    ) -> MotionObservation? {
        let inWindow = samples
            .filter { $0.isFinite && $0.uptime >= momentUptime - before && $0.uptime <= momentUptime + after }
            .sorted { $0.uptime < $1.uptime }
        // Keep a sample only once ~one period has passed since the last kept one.
        let minimumSpacing = 0.8 / Double(max(rateHz, 1))
        var kept: [MotionSample] = []
        for sample in inWindow where kept.last.map({ sample.uptime - $0.uptime >= minimumSpacing }) ?? true {
            kept.append(sample)
        }
        guard let first = kept.first, let last = kept.last else { return nil }
        let ms = { (uptime: TimeInterval) in SensorClock.milliseconds(uptime - momentUptime) }
        let round4 = { (values: [Double]) in values.map { LocationObservation.rounded($0, places: 4) } }
        return MotionObservation(
            sampleRateHz: rateHz,
            windowStartMs: ms(first.uptime),
            windowMs: SensorClock.milliseconds(last.uptime - first.uptime),
            sampleCount: kept.count,
            samples: kept.map {
                Sample(
                    tMs: ms($0.uptime),
                    gravity: round4($0.gravity),
                    userAcceleration: round4($0.userAcceleration),
                    rotationRate: round4($0.rotationRate),
                    attitudeQuaternion: round4($0.attitudeQuaternion),
                    magneticField: $0.magneticField.map { $0.map { LocationObservation.rounded($0, places: 2) } },
                    magneticAccuracy: $0.magneticAccuracy
                )
            },
            summary: summary(kept, round: round4)
        )
    }

    private static func summary(_ samples: [MotionSample], round: ([Double]) -> [Double]) -> Summary {
        let acceleration = samples.map(\.userAcceleration)
        let rotation = samples.map(\.rotationRate)
        let accelerationMagnitudes = acceleration.map(magnitude)
        let rotationMagnitudes = rotation.map(magnitude)
        let scalar = { (value: Double) in LocationObservation.rounded(value, places: 4) }
        return Summary(
            accelerationMean: round(axis(acceleration, mean)),
            accelerationStd: round(axis(acceleration, standardDeviation)),
            accelerationMin: round(axis(acceleration) { $0.min() ?? 0 }),
            accelerationMax: round(axis(acceleration) { $0.max() ?? 0 }),
            rotationMean: round(axis(rotation, mean)),
            rotationStd: round(axis(rotation, standardDeviation)),
            rotationMin: round(axis(rotation) { $0.min() ?? 0 }),
            rotationMax: round(axis(rotation) { $0.max() ?? 0 }),
            rmsAcceleration: scalar(rms(accelerationMagnitudes)),
            rmsRotation: scalar(rms(rotationMagnitudes)),
            peakAcceleration: scalar(accelerationMagnitudes.max() ?? 0),
            peakRotation: scalar(rotationMagnitudes.max() ?? 0),
            startQuaternion: round(samples.first?.attitudeQuaternion ?? []),
            endQuaternion: round(samples.last?.attitudeQuaternion ?? [])
        )
    }

    private static func axis(_ vectors: [[Double]], _ reduce: ([Double]) -> Double) -> [Double] {
        (0..<3).map { index in reduce(vectors.compactMap { $0.indices.contains(index) ? $0[index] : nil }) }
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        return (values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)).squareRoot()
    }

    static func rms(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    private static func magnitude(_ vector: [Double]) -> Double {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}

/// Latest `CLHeading` reading of the capture, reduced to scalars.
struct HeadingSample: Equatable, Sendable {
    let magneticHeading: Double?
    let trueHeading: Double?
    let headingAccuracy: Double?
    /// Raw geomagnetic vector (µT) from the heading.
    let field: [Double]?
    let observedAt: Date
}
