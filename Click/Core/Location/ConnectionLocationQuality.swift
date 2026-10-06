import CoreLocation
import Foundation

/// The one location-quality policy shared by Tap to Connect and QR. Horizontal accuracy is the
/// OS's uncertainty radius, not a guarantee: 5 m is never promised, only never thrown away.
/// All values are tunable from physical-device testing (see the location accuracy spec §23).
enum ConnectionLocationQuality {
    /// Diagnostics tier: about the best a phone reports, enough to tell a building from the street.
    static let excellentAccuracy: CLLocationAccuracy = 5
    /// A fix this tight (time-adjusted) ends a wait once the minimum window has passed. Waiting
    /// on to `excellentAccuracy` would hold Tap/QR results for little gain, and a 20 m fix
    /// never ends a wait merely because it arrived first.
    static let goodAccuracy: CLLocationAccuracy = 10
    /// Diagnostics tier: still useful for a place, too coarse to separate a building from the street.
    static let usableAccuracy: CLLocationAccuracy = 25
    /// Coarser fixes are never attached to an encounter. Also keeps QR scans clear of the
    /// server's 100 m proximity check.
    static let maximumUsefulAccuracy: CLLocationAccuracy = 50

    /// Fixes keep arriving after the first one; never settle before this much sampling.
    static let minimumCaptureDuration: TimeInterval = 1.5
    /// Longest wait for a cold capture (no warm-up before the moment, e.g. a Click link opened
    /// from the system camera): the previous scan-time timeout, so that path is never slower.
    static let coldCaptureDuration: TimeInterval = 3
    /// A capture never holds a connection past this long after it started.
    static let hardCaptureLimit: TimeInterval = 8
    /// Extra time an in-flow connection may wait after its moment for a better fix.
    static let inFlowGrace: TimeInterval = 1

    /// A cached fix may seed a capture only if it is at most this old (tagged with its real time).
    static let maximumSeedAge: TimeInterval = 10
    /// Fixes older than this before the connection moment describe a different place.
    static let selectionLookback: TimeInterval = 8
    /// Walking pace: a fix `t` seconds away from the moment may be this far off per second.
    static let assumedDriftMetersPerSecond: Double = 1.5
    /// Effective radii closer than this are a tie, broken by vertical validity.
    static let tieTolerance: Double = 0.5

    /// Warm capture stops by itself if a visible flow sits idle this long.
    static let maximumWarmDuration: TimeInterval = 120
    /// Ring-buffer size for fixes and altimeter samples.
    static let bufferCapacity = 64

    /// How long a flow may wait at its connection moment, and what ends the wait early.
    struct Wait: Equatable, Sendable {
        let settleAccuracy: CLLocationAccuracy
        let grace: TimeInterval

        /// Tap / QR: location has been warming during the interaction.
        static let inFlow = Wait(settleAccuracy: goodAccuracy, grace: inFlowGrace)
        /// No warm-up (e.g. a Click link opened outside the scanner).
        static let cold = Wait(settleAccuracy: goodAccuracy, grace: coldCaptureDuration)
    }

    /// Coarse accuracy band for diagnostics and aggregate telemetry.
    static func tier(_ accuracy: CLLocationAccuracy) -> String {
        switch accuracy {
        case ...excellentAccuracy: "excellent"
        case ...goodAccuracy: "good"
        case ...usableAccuracy: "usable"
        case ...maximumUsefulAccuracy: "coarse"
        default: "unusable"
        }
    }

    static func isUseful(_ fix: LocationObservation) -> Bool {
        fix.horizontalAccuracyMeters <= maximumUsefulAccuracy
    }

    /// Reported uncertainty grown by how far the fix is in time from the connection moment.
    static func effectiveRadius(_ fix: LocationObservation, moment: Date) -> Double {
        fix.horizontalAccuracyMeters + assumedDriftMetersPerSecond * abs(fix.observedAt.timeIntervalSince(moment))
    }

    /// The most useful fix for an event at `moment`: full accuracy first, then the smallest
    /// time-adjusted radius, then a valid vertical reading, then the closest in time.
    static func best(_ fixes: [LocationObservation], around moment: Date, until latest: Date) -> LocationObservation? {
        let earliest = moment.addingTimeInterval(-selectionLookback)
        return fixes
            .filter { isUseful($0) && $0.observedAt >= earliest && $0.observedAt <= latest }
            .min { isBetter($0, than: $1, moment: moment) }
    }

    static func isBetter(_ a: LocationObservation, than b: LocationObservation, moment: Date) -> Bool {
        if a.isFullAccuracy != b.isFullAccuracy { return a.isFullAccuracy }
        let radiusA = effectiveRadius(a, moment: moment)
        let radiusB = effectiveRadius(b, moment: moment)
        if abs(radiusA - radiusB) > tieTolerance { return radiusA < radiusB }
        if a.hasValidVertical != b.hasValidVertical { return a.hasValidVertical }
        return abs(a.observedAt.timeIntervalSince(moment)) < abs(b.observedAt.timeIntervalSince(moment))
    }

    /// Several consistent fixes near the moment, combined (supplemental to `best`, which stays
    /// canonical). An inverse-variance weighted mean over time-adjusted radii; fixes farther from
    /// the best fix than their combined radii (a jump, a multipath outlier) are left out. Phone
    /// GPS errors are correlated over seconds, so the radius is never claimed below half the best
    /// fix's. Nil with fewer than two consistent fixes.
    struct Fused: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
        let fixCount: Int
        /// Time between the earliest and latest fix used.
        let spanMs: Int
    }

    static func fused(_ fixes: [LocationObservation], around moment: Date, until latest: Date) -> Fused? {
        guard let anchor = best(fixes, around: moment, until: latest) else { return nil }
        let earliest = moment.addingTimeInterval(-selectionLookback)
        let anchorRadius = effectiveRadius(anchor, moment: moment)
        let metersPerDegree = 111_320.0
        let cosLat = cos(anchor.latitude * .pi / 180)
        let offset = { (fix: LocationObservation) -> (x: Double, y: Double) in
            ((fix.longitude - anchor.longitude) * metersPerDegree * cosLat, (fix.latitude - anchor.latitude) * metersPerDegree)
        }
        let consistent = fixes.filter { fix in
            guard isUseful(fix), fix.isFullAccuracy == anchor.isFullAccuracy,
                  fix.observedAt >= earliest, fix.observedAt <= latest else { return false }
            let (x, y) = offset(fix)
            return (x * x + y * y).squareRoot() <= effectiveRadius(fix, moment: moment) + anchorRadius
        }
        guard consistent.count >= 2 else { return nil }
        var sumW = 0.0, sumX = 0.0, sumY = 0.0
        for fix in consistent {
            let radius = max(1, effectiveRadius(fix, moment: moment))
            let w = 1 / (radius * radius)
            let (x, y) = offset(fix)
            sumW += w
            sumX += w * x
            sumY += w * y
        }
        let times = consistent.map(\.observedAt)
        return Fused(
            latitude: anchor.latitude + (sumY / sumW) / metersPerDegree,
            longitude: anchor.longitude + (sumX / sumW) / (metersPerDegree * cosLat),
            radiusMeters: max((1 / sumW).squareRoot(), anchorRadius / 2),
            fixCount: consistent.count,
            spanMs: SensorClock.milliseconds((times.max() ?? moment).timeIntervalSince(times.min() ?? moment))
        )
    }

    // MARK: Refinement after the moment

    /// After a connection the phones usually stay where they met while the result is read, and
    /// GPS keeps converging for tens of seconds. Fixes from that time, while the phone stays
    /// put, describe the same spot, so a short follow-up can tighten the moment's fix without
    /// making anyone wait.
    static let refinementWindow: TimeInterval = 20
    /// A refinement must shrink the radius to at most this share of the moment's.
    static let refinementGain = 0.8
    /// Linear acceleration (g, RMS over a second) above which the phone is being walked with,
    /// once it lasts `movingSeconds` in a row (lifting the phone once does not count).
    static let stationaryAccelerationRMS = 0.12
    static let movingSeconds = 3
    /// A fix reporting this speed (m/s) or more was taken on the move.
    static let stationarySpeed: Double = 0.8

    /// A tighter fix for the moment from `later` fixes (taken after it, while still), or nil
    /// unless clearly better. The position is the inverse-variance mean of the fixes agreeing
    /// with the best one; the radius is that best fix's own, as reported by Core Location (never
    /// a statistically shrunk one, since consecutive fixes share most of their error). A result
    /// that disagrees with the moment's fix means the phone moved, and is dropped.
    static func refined(_ original: LocationObservation, later: [LocationObservation], moment: Date) -> LocationObservation? {
        let still = later.filter {
            isUseful($0) && $0.isFullAccuracy == original.isFullAccuracy && $0.observedAt > moment
                && ($0.speedMetersPerSecond ?? 0) < stationarySpeed
        }
        guard let best = still.min(by: { $0.horizontalAccuracyMeters < $1.horizontalAccuracyMeters }),
              best.horizontalAccuracyMeters <= original.horizontalAccuracyMeters * refinementGain else { return nil }
        let agreeing = still.filter {
            meters(from: $0, to: best) <= $0.horizontalAccuracyMeters + best.horizontalAccuracyMeters
        }
        var sumW = 0.0, sumLat = 0.0, sumLon = 0.0
        for fix in agreeing {
            let radius = max(1, fix.horizontalAccuracyMeters)
            let w = 1 / (radius * radius)
            sumW += w
            sumLat += w * fix.latitude
            sumLon += w * fix.longitude
        }
        let result = best.moved(to: sumLat / sumW, longitude: sumLon / sumW)
        guard meters(from: result, to: original) <= original.horizontalAccuracyMeters + best.horizontalAccuracyMeters else { return nil }
        return result
    }

    /// Ground distance (m) between two nearby fixes (equirectangular; exact enough within km).
    static func meters(from a: LocationObservation, to b: LocationObservation) -> Double {
        let metersPerDegree = 111_320.0
        let x = (b.longitude - a.longitude) * metersPerDegree * cos(a.latitude * .pi / 180)
        let y = (b.latitude - a.latitude) * metersPerDegree
        return (x * x + y * y).squareRoot()
    }

    /// True once the minimum window has passed and `best` is at least `settleAccuracy`.
    static func isSettled(_ best: LocationObservation?, moment: Date, startedAt: Date, now: Date, wait: Wait) -> Bool {
        guard let best, now.timeIntervalSince(startedAt) >= minimumCaptureDuration else { return false }
        return effectiveRadius(best, moment: moment) <= wait.settleAccuracy
    }

    /// When a flow stops waiting: `grace` after its moment, bounded by the hard limit, but
    /// never before the minimum sampling window. A long-warm capture may already be past it.
    static func deadline(moment: Date, startedAt: Date, wait: Wait) -> Date {
        let bounded = min(moment.addingTimeInterval(wait.grace), startedAt.addingTimeInterval(hardCaptureLimit))
        return max(startedAt.addingTimeInterval(minimumCaptureDuration), bounded)
    }
}
