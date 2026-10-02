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
