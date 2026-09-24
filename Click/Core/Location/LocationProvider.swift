import CoreLocation
import Foundation

/// Location fixes for features that need the user's position (Home discovery counts, Map,
/// Tap to Connect evidence, event check-in, hub geofences).
///
/// Never prompts: callers ask `PermissionCoordinator` after explicit user intent. Every call
/// is bounded by a timeout so no feature waits forever for impossible precision (spec §23.7).
@MainActor
public final class LocationProvider {
    public static let shared = LocationProvider()

    private let manager = CLLocationManager()
    public private(set) var lastFix: CLLocation?

    public init() {}

    public var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    /// Whether the user granted precise (not approximate) location.
    public var isPrecise: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    /// A recent fix, reusing the last one when it is younger than `maximumAge`.
    /// Returns `nil` when location is not authorized or no fix arrives in time.
    public func currentLocation(
        maximumAge: TimeInterval = 120,
        acceptableAccuracy: CLLocationAccuracy = 150,
        timeout: Duration = .seconds(8)
    ) async -> CLLocation? {
        if let lastFix, -lastFix.timestamp.timeIntervalSinceNow < maximumAge,
           lastFix.horizontalAccuracy <= acceptableAccuracy {
            return lastFix
        }
        guard isAuthorized else { return nil }
        let fix = await Self.bestFix(acceptableAccuracy: acceptableAccuracy, timeout: timeout)
        if let fix { lastFix = fix }
        return fix
    }

    /// Progressive high-accuracy capture for proximity/check-in evidence: returns as soon as a fix
    /// reaches `targetAccuracy`, otherwise the most accurate fix seen before the timeout.
    public func preciseLocation(
        targetAccuracy: CLLocationAccuracy = 20,
        timeout: Duration = .seconds(6)
    ) async -> CLLocation? {
        guard isAuthorized else { return nil }
        let fix = await Self.bestFix(acceptableAccuracy: targetAccuracy, timeout: timeout)
        if let fix { lastFix = fix }
        return fix
    }

    /// Records a fix produced elsewhere (e.g. the Map's live updates) so other features reuse it.
    public func record(_ location: CLLocation) {
        lastFix = location
    }

    private nonisolated static func bestFix(
        acceptableAccuracy: CLLocationAccuracy,
        timeout: Duration
    ) async -> CLLocation? {
        let best = BestFix()
        let updates = Task {
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
                    if await best.offer(location, acceptable: acceptableAccuracy) { return }
                }
            } catch {
                return
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            updates.cancel()
        }
        await updates.value
        deadline.cancel()
        return await best.value
    }
}

/// Holds the most accurate fix seen during a bounded capture.
private actor BestFix {
    private(set) var value: CLLocation?

    /// Stores the fix if it improves accuracy; returns true once it is good enough to stop.
    func offer(_ location: CLLocation, acceptable: CLLocationAccuracy) -> Bool {
        if value == nil || location.horizontalAccuracy < value!.horizontalAccuracy {
            value = location
        }
        return location.horizontalAccuracy <= acceptable
    }
}
