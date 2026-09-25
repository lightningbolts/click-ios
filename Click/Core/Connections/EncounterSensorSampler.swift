import AVFoundation
import CoreMotion
import Foundation
import UIKit

/// Opt-in encounter sensor context (Privacy → Encounter context). Barometric elevation and
/// ambient noise are each sampled only when the user turned them on; nothing is stored on the
/// device and the noise sample is a level, never audio (the temporary file is deleted at once).
/// `elevation_category` is derived by the server from the barometric value (terrain-corrected),
/// as for KMP.
@MainActor
enum EncounterSensorSampler {
    /// - Parameter includeNoise: false while the microphone is busy (the tap's ultrasonic listen).
    /// - Parameter includeHardware: the connect-time snapshot (light proxy, motion, heading,
    ///   battery; KMP `HardwareVibeMonitor`). Off for later sensor-only patches so they never
    ///   overwrite the moment of the connection.
    static func sample(
        settings: SettingsStore,
        includeNoise: Bool = true,
        includeHardware: Bool = false,
        timeout: Duration = .seconds(2)
    ) async -> EncounterSensorContext {
        let wantsElevation = settings.barometricContextOptIn
        let wantsNoise = includeNoise && settings.ambientNoiseOptIn
        async let meters = wantsElevation ? barometricElevation(timeout: timeout) : nil
        async let decibels = wantsNoise ? ambientNoiseDecibels(duration: timeout) : nil
        async let hardware = includeHardware ? HardwareVibeSampler.snapshot() : HardwareVibeSampler.Snapshot()
        let (elevation, noise, vibe) = await (meters, decibels, hardware)
        return EncounterSensorContext(
            noiseLevel: noise.map(noiseLevel(decibels:)),
            noiseDecibels: noise.map { ($0 * 10).rounded() / 10 },
            barometricElevationMeters: elevation.map { ($0 * 10).rounded() / 10 },
            luxLevel: vibe.luxLevel,
            motionVariance: vibe.motionVariance,
            compassAzimuth: vibe.compassAzimuth,
            batteryLevel: vibe.batteryLevel
        )
    }

    /// KMP `noiseLevelCategoryFromApproximateDb` tiers, as the enum names KMP writes.
    nonisolated static func noiseLevel(decibels: Double) -> String {
        switch decibels {
        case ..<35: "VERY_QUIET"
        case ..<55: "QUIET"
        case ..<75: "MODERATE"
        case ..<90: "LOUD"
        default: "VERY_LOUD"
        }
    }

    /// KMP's approximation: average power (dBFS) + 90, clamped to 0…100.
    nonisolated static func approximateDecibels(averagePower: Float) -> Double {
        min(100, max(0, Double(averagePower) + 90))
    }

    private static func barometricElevation(timeout: Duration) async -> Double? {
        guard CMAltimeter.isAbsoluteAltitudeAvailable() else { return nil }
        let altimeter = CMAltimeter()
        let meters: Double? = await withCheckedContinuation { continuation in
            let box = ResumeOnce(continuation)
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { data, _ in
                box.resume(data.map { $0.altitude })
            }
            Task {
                try? await Task.sleep(for: timeout)
                box.resume(nil)
            }
        }
        altimeter.stopAbsoluteAltitudeUpdates()
        return meters
    }

    /// Meters the microphone for `duration` (KMP `IosAmbientNoiseMonitor`). Never prompts:
    /// permission is asked when the toggle is turned on.
    private static func ambientNoiseDecibels(duration: Duration) async -> Double? {
        guard AVAudioApplication.shared.recordPermission == .granted else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("click-ambient-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await AudioSessionController.shared.activate(.measurement)
        } catch {
            return nil
        }
        defer { AudioSessionController.shared.deactivate() }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 12_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return nil }
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else { return nil }
        try? await Task.sleep(for: duration)
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        recorder.stop()
        return approximateDecibels(averagePower: power)
    }

    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<Double?, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<Double?, Never>) { self.continuation = continuation }
        func resume(_ value: Double?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// Connect-time hardware snapshot (KMP `HardwareVibeMonitor.ios`): ~0.5 s of accelerometer
/// variance and compass heading, plus battery and a light proxy. iOS exposes no ambient-light
/// sensor, so `luxLevel` is screen brightness × 1000 exactly as KMP wrote it. No permission
/// prompts; unavailable readings stay nil.
@MainActor
enum HardwareVibeSampler {
    struct Snapshot: Equatable, Sendable {
        var luxLevel: Double?
        var motionVariance: Double?
        var compassAzimuth: Double?
        var batteryLevel: Int?
    }

    static let window: Duration = .milliseconds(500)
    private nonisolated static let gravity = 9.80665

    static func snapshot() async -> Snapshot {
        var result = Snapshot(luxLevel: luxProxy(), batteryLevel: batteryPercent())
        let motion = CMMotionManager()
        let readings = Readings()
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.02
            motion.startAccelerometerUpdates(to: .main) { data, _ in
                guard let a = data?.acceleration else { return }
                readings.addMagnitude((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() * gravity)
            }
        }
        let frame: CMAttitudeReferenceFrame = .xMagneticNorthZVertical
        if motion.isDeviceMotionAvailable, CMMotionManager.availableAttitudeReferenceFrames().contains(frame) {
            motion.deviceMotionUpdateInterval = 0.05
            motion.startDeviceMotionUpdates(using: frame, to: .main) { data, _ in
                // `heading` is degrees clockwise from magnetic north; negative until calibrated.
                guard let value = data?.heading, value.isFinite, value >= 0 else { return }
                readings.setHeading(value.truncatingRemainder(dividingBy: 360))
            }
        }
        try? await Task.sleep(for: window)
        motion.stopAccelerometerUpdates()
        motion.stopDeviceMotionUpdates()
        let (magnitudes, heading) = readings.values
        result.motionVariance = variance(magnitudes)
        result.compassAzimuth = heading.map { ($0 * 10).rounded() / 10 }
        return result
    }

    /// Motion callbacks write here; read once after the window closes.
    private final class Readings: @unchecked Sendable {
        private let lock = NSLock()
        private var magnitudes: [Double] = []
        private var heading: Double?

        func addMagnitude(_ value: Double) { lock.withLock { magnitudes.append(value) } }
        func setHeading(_ value: Double) { lock.withLock { heading = value } }
        var values: ([Double], Double?) { lock.withLock { (magnitudes, heading) } }
    }

    /// Population variance of acceleration magnitudes (m/s²); nil with fewer than 3 samples.
    nonisolated static func variance(_ values: [Double]) -> Double? {
        guard values.count >= 3 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let value = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return value.isFinite ? value : nil
    }

    private static func luxProxy() -> Double? {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
        guard let brightness = screen?.brightness, brightness.isFinite, brightness >= 0 else { return nil }
        return (Double(brightness) * 1000).rounded()
    }

    private static func batteryPercent() -> Int? {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        let level = device.batteryLevel
        guard level.isFinite, level >= 0 else { return nil }
        return min(100, max(0, Int((level * 100).rounded())))
    }
}
