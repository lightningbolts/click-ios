import CoreLocation
import Foundation

/// One Core Location fix reduced to explicit scalar measurements (never a persisted
/// `CLLocation`). Each phone reports only its own observation; nothing here is ever combined
/// with another participant's reading.
public struct LocationObservation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    /// Radius of uncertainty (m) — not a correctness score.
    let horizontalAccuracyMeters: Double
    /// nil when Core Location reported no valid altitude (`verticalAccuracy <= 0`).
    let verticalAccuracyMeters: Double?

    let altitudeMeters: Double?
    let ellipsoidalAltitudeMeters: Double?

    let observedAt: Date
    /// The OS's logical building floor, when it knows it. Never inferred from altitude.
    let floorLevel: Int?

    /// false when the user granted only approximate location.
    let isFullAccuracy: Bool

    /// Diagnostics only; not sent to the server.
    let isSimulatedBySoftware: Bool?
    let isProducedByAccessory: Bool?

    var hasValidVertical: Bool { verticalAccuracyMeters != nil }
}

extension LocationObservation {
    /// A fix stamped further in the future than this is a clock fault.
    static let futureSkewTolerance: TimeInterval = 2

    /// Validates a fix: finite in-range coordinate (not null island), non-negative horizontal
    /// accuracy, and a timestamp no older than `maximumAge`. Core Location altitude is kept
    /// only with a positive `verticalAccuracy`.
    init?(_ location: CLLocation, isFullAccuracy: Bool, maximumAge: TimeInterval, now: Date = .now) {
        let coordinate = location.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate),
              !(coordinate.latitude == 0 && coordinate.longitude == 0),
              location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 else { return nil }
        let age = now.timeIntervalSince(location.timestamp)
        guard age <= maximumAge, age >= -Self.futureSkewTolerance else { return nil }

        let verticalValid = location.verticalAccuracy.isFinite && location.verticalAccuracy > 0
        self.init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            verticalAccuracyMeters: verticalValid ? location.verticalAccuracy : nil,
            altitudeMeters: verticalValid && location.altitude.isFinite ? location.altitude : nil,
            ellipsoidalAltitudeMeters: verticalValid && location.ellipsoidalAltitude.isFinite ? location.ellipsoidalAltitude : nil,
            observedAt: location.timestamp,
            floorLevel: location.floor?.level,
            isFullAccuracy: isFullAccuracy,
            isSimulatedBySoftware: location.sourceInformation?.isSimulatedBySoftware,
            isProducedByAccessory: location.sourceInformation?.isProducedByAccessory
        )
    }

    /// Request-body keys (= `connection_encounters` column names) for this observation's
    /// quality. The coordinate itself travels under each endpoint's existing keys.
    var qualityColumns: [String: Any] {
        var out: [String: Any] = [
            "gps_horizontal_accuracy_m": Self.rounded(horizontalAccuracyMeters, places: 2),
            "gps_observed_at": Self.timestampString(observedAt),
            "gps_full_accuracy": isFullAccuracy
        ]
        if let verticalAccuracyMeters {
            out["gps_vertical_accuracy_m"] = Self.rounded(verticalAccuracyMeters, places: 2)
            if let altitudeMeters { out["gps_altitude_m"] = Self.rounded(altitudeMeters, places: 2) }
            if let ellipsoidalAltitudeMeters { out["gps_ellipsoidal_altitude_m"] = Self.rounded(ellipsoidalAltitudeMeters, places: 2) }
        }
        if let floorLevel { out["gps_floor"] = floorLevel }
        return out
    }

    static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
