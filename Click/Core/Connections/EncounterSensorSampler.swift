import CoreMotion
import Foundation

/// Opt-in encounter sensor context. Only the barometer is sampled on iOS (Privacy → Encounter
/// context → "Barometric context"); ambient noise has no iOS opt-in UI yet, so it is never
/// captured. Nothing is sampled unless the user opted in.
@MainActor
enum EncounterSensorSampler {
    static func sample(settings: SettingsStore, timeout: Duration = .seconds(2)) async -> EncounterSensorContext {
        guard settings.barometricContextOptIn, CMAltimeter.isAbsoluteAltitudeAvailable() else { return EncounterSensorContext() }
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
        return EncounterSensorContext(barometricElevationMeters: meters.map { ($0 * 10).rounded() / 10 })
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
