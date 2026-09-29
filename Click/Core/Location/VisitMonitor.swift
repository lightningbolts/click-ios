import CoreLocation
import Foundation

/// iOS visit monitoring (spec F6 §8b): the system reports arrivals at places you stay, even when
/// Click isn't running, at very low battery cost. Used only for the opt-in "near a past meeting
/// spot" reminder; no background mode or continuous tracking. Needs "Always" location.
@MainActor
final class VisitMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorization: CheckedContinuation<Bool, Never>?
    /// Called with the place of each arrival (never departures).
    var onArrival: ((CLLocationCoordinate2D) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorizedAlways: Bool { manager.authorizationStatus == .authorizedAlways }

    /// Asks for "Always" (iOS may first grant it provisionally), then starts. False when declined.
    func requestAlwaysAndStart() async -> Bool {
        if !isAuthorizedAlways {
            let granted = await withCheckedContinuation { continuation in
                authorization = continuation
                manager.requestAlwaysAuthorization()
            }
            guard granted else { return false }
        }
        manager.startMonitoringVisits()
        return true
    }

    func startIfAuthorized() {
        if isAuthorizedAlways { manager.startMonitoringVisits() }
    }

    func stop() {
        manager.stopMonitoringVisits()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let continuation = self.authorization else { return }
            self.authorization = nil
            continuation.resume(returning: status == .authorizedAlways)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard visit.departureDate == .distantFuture else { return }
        let coordinate = visit.coordinate
        Task { @MainActor in self.onArrival?(coordinate) }
    }
}
