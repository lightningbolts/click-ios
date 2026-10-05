import Foundation

/// One phone's barometric altitude reading with the uncertainty the altimeter reported for it.
/// Independent of Core Location's altitude; neither ever overwrites the other.
public struct AltitudeObservation: Codable, Equatable, Sendable {
    /// Absolute altitude estimate (m AMSL), sent as the legacy `exact_barometric_elevation_m`
    /// key — an estimate, not exact.
    let absoluteAltitudeMeters: Double?
    /// Estimated 1σ uncertainty of `absoluteAltitudeMeters` (`CMAbsoluteAltitudeData.accuracy`).
    let accuracyMeters: Double?
    /// Recommended display precision (`CMAbsoluteAltitudeData.precision`).
    let precisionMeters: Double?

    /// Change since the capture's first relative-altitude event, with its pressure reading.
    let relativeAltitudeMeters: Double?
    let pressureKPa: Double?

    let observedAt: Date

    /// Request-body keys, equal to the `connection_encounters` column names. Pressure and the
    /// relative change are sent even before the altimeter's first absolute fix (which can take
    /// several seconds); accuracy and precision only ever describe the absolute altitude.
    var columns: [String: Any] {
        var out: [String: Any] = [:]
        if let absoluteAltitudeMeters {
            out["exact_barometric_elevation_m"] = LocationObservation.rounded(absoluteAltitudeMeters, places: 1)
            if let accuracyMeters { out["barometric_accuracy_m"] = LocationObservation.rounded(accuracyMeters, places: 2) }
            if let precisionMeters { out["barometric_precision_m"] = LocationObservation.rounded(precisionMeters, places: 2) }
        }
        if let relativeAltitudeMeters { out["barometric_relative_altitude_m"] = LocationObservation.rounded(relativeAltitudeMeters, places: 2) }
        if let pressureKPa { out["barometric_pressure_kpa"] = LocationObservation.rounded(pressureKPa, places: 3) }
        return out
    }
}

/// Raw altimeter events collected during a capture.
struct AbsoluteAltitudeSample: Equatable, Sendable {
    let altitudeMeters: Double
    let accuracyMeters: Double
    let precisionMeters: Double
    let observedAt: Date
}

struct RelativeAltitudeSample: Equatable, Sendable {
    let relativeAltitudeMeters: Double
    let pressureKPa: Double
    let observedAt: Date
}

/// Deliberately simple stabilization of one phone's own altimeter series: keep the samples
/// near the connection moment, prefer the lowest reported uncertainty, and among comparably
/// accurate samples take the median reading — an actual sample, so its reported uncertainty
/// stays truthful. No floor is inferred from the series.
enum AltitudeStabilizer {
    /// The altimeter never holds a connection longer than this after it started (the existing
    /// encounter-sensor window).
    static let sampleWindow: TimeInterval = 2

    /// Samples within this of the best uncertainty count as comparably accurate.
    static func comparableBand(bestAccuracy: Double) -> Double { max(1, bestAccuracy * 0.5) }

    static func stabilized(
        absolute: [AbsoluteAltitudeSample],
        relative: [RelativeAltitudeSample],
        around moment: Date,
        lookback: TimeInterval = ConnectionLocationQuality.selectionLookback,
        until latest: Date
    ) -> AltitudeObservation? {
        let earliest = moment.addingTimeInterval(-lookback)
        let inWindow = { (date: Date) in date >= earliest && date <= latest }
        let valid = absolute.filter {
            inWindow($0.observedAt) && $0.altitudeMeters.isFinite && $0.accuracyMeters.isFinite && $0.accuracyMeters >= 0
        }
        let pressures = relative.filter {
            inWindow($0.observedAt) && $0.relativeAltitudeMeters.isFinite && $0.pressureKPa.isFinite && $0.pressureKPa > 0
        }

        let chosen: AbsoluteAltitudeSample? = valid.map(\.accuracyMeters).min().flatMap { bestAccuracy in
            let comparable = valid
                .filter { $0.accuracyMeters <= bestAccuracy + comparableBand(bestAccuracy: bestAccuracy) }
                .sorted { $0.altitudeMeters < $1.altitudeMeters }
            return comparable[(comparable.count - 1) / 2]
        }
        let anchor = chosen?.observedAt ?? moment
        let pressure = pressures.min {
            abs($0.observedAt.timeIntervalSince(anchor)) < abs($1.observedAt.timeIntervalSince(anchor))
        }
        guard chosen != nil || pressure != nil else { return nil }
        return AltitudeObservation(
            absoluteAltitudeMeters: chosen?.altitudeMeters,
            accuracyMeters: chosen?.accuracyMeters,
            precisionMeters: chosen?.precisionMeters,
            relativeAltitudeMeters: pressure?.relativeAltitudeMeters,
            pressureKPa: pressure?.pressureKPa,
            observedAt: anchor
        )
    }
}
