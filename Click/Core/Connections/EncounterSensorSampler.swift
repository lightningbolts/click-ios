import AVFoundation
import CoreMotion
import Foundation

/// Opt-in encounter sensor context (Privacy → Encounter context). Barometric elevation and
/// ambient noise are each sampled only when the user turned them on; nothing is stored on the
/// device and the noise sample is a level, never audio (the temporary file is deleted at once).
/// `elevation_category` is derived by the server from the barometric value (terrain-corrected),
/// as for KMP.
@MainActor
enum EncounterSensorSampler {
    /// - Parameter includeNoise: false while the microphone is busy (the tap's ultrasonic listen).
    static func sample(settings: SettingsStore, includeNoise: Bool = true, timeout: Duration = .seconds(2)) async -> EncounterSensorContext {
        let wantsElevation = settings.barometricContextOptIn
        let wantsNoise = includeNoise && settings.ambientNoiseOptIn
        async let meters = wantsElevation ? barometricElevation(timeout: timeout) : nil
        async let decibels = wantsNoise ? ambientNoiseDecibels(duration: timeout) : nil
        let (elevation, noise) = await (meters, decibels)
        return EncounterSensorContext(
            noiseLevel: noise.map(noiseLevel(decibels:)),
            noiseDecibels: noise.map { ($0 * 10).rounded() / 10 },
            barometricElevationMeters: elevation.map { ($0 * 10).rounded() / 10 }
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
        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("click-ambient-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            return nil
        }
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
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
