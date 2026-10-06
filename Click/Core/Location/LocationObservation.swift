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

    /// Source provenance (`CLLocationSourceInformation`).
    let isSimulatedBySoftware: Bool?
    let isProducedByAccessory: Bool?

    /// Velocity; nil when Core Location reported it invalid (negative). Never substituted.
    var speedMetersPerSecond: Double? = nil
    var speedAccuracyMetersPerSecond: Double? = nil
    var courseDegrees: Double? = nil
    var courseAccuracyDegrees: Double? = nil

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
        let speedValid = location.speed.isFinite && location.speed >= 0
        let courseValid = location.course.isFinite && location.course >= 0
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
            isProducedByAccessory: location.sourceInformation?.isProducedByAccessory,
            speedMetersPerSecond: speedValid ? location.speed : nil,
            speedAccuracyMetersPerSecond: speedValid ? Self.nonNegative(location.speedAccuracy) : nil,
            courseDegrees: courseValid ? location.course : nil,
            courseAccuracyDegrees: courseValid ? Self.nonNegative(location.courseAccuracy) : nil
        )
    }

    /// The same fix (its accuracy, time and altitude) at another position.
    func moved(to latitude: Double, longitude: Double) -> LocationObservation {
        LocationObservation(
            latitude: latitude, longitude: longitude,
            horizontalAccuracyMeters: horizontalAccuracyMeters, verticalAccuracyMeters: verticalAccuracyMeters,
            altitudeMeters: altitudeMeters, ellipsoidalAltitudeMeters: ellipsoidalAltitudeMeters,
            observedAt: observedAt, floorLevel: floorLevel, isFullAccuracy: isFullAccuracy,
            isSimulatedBySoftware: isSimulatedBySoftware, isProducedByAccessory: isProducedByAccessory,
            speedMetersPerSecond: speedMetersPerSecond, speedAccuracyMetersPerSecond: speedAccuracyMetersPerSecond,
            courseDegrees: courseDegrees, courseAccuracyDegrees: courseAccuracyDegrees
        )
    }

    /// Core Location marks invalid accuracies with negative values.
    private static func nonNegative(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
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
        if let speedMetersPerSecond {
            out["gps_speed_mps"] = Self.rounded(speedMetersPerSecond, places: 2)
            if let speedAccuracyMetersPerSecond { out["gps_speed_accuracy_mps"] = Self.rounded(speedAccuracyMetersPerSecond, places: 2) }
        }
        if let courseDegrees {
            out["gps_course_deg"] = Self.rounded(courseDegrees, places: 1)
            if let courseAccuracyDegrees { out["gps_course_accuracy_deg"] = Self.rounded(courseAccuracyDegrees, places: 1) }
        }
        if let isSimulatedBySoftware { out["gps_simulated"] = isSimulatedBySoftware }
        if let isProducedByAccessory { out["gps_external_accessory"] = isProducedByAccessory }
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
