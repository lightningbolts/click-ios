import Foundation

/// Fills in this phone's barometric altitude a few seconds after a connection that completed
/// before the altimeter's first absolute fix (common on a quick QR scan or tap), so the
/// encounter still gets its height above ground without the connect waiting for it.
///
/// It takes over the capture's running altimeter, waits at most
/// `AltitudeStabilizer.followUpWindow` after the moment for a fix, stops the altimeter, and —
/// once the flow confirms which connections it logged — sends the altitude at the moment to
/// `POST /api/connections/encounter-altitude`. The server fills only this user's rows for that
/// exact moment and never overwrites a stored altitude. Nothing is sent when the flow cancels,
/// never confirms, or no usable fix arrives; failures are silent (the connection is unaffected).
@MainActor
final class EncounterAltitudeFollowUp {
    /// After the fix, how long the flow has to confirm the connections it logged (a tap can
    /// wait for its peer and the people review).
    static let confirmationWindow: TimeInterval = 120
    static let maximumConnections = 20
    private static let pollInterval: Duration = .milliseconds(250)

    private let feed: AltimeterFeed
    private let moment: Date
    private let api: ClickAPIClient
    private var connectionIDs: [String]?
    private var isCancelled = false

    private init(feed: AltimeterFeed, moment: Date, api: ClickAPIClient) {
        self.feed = feed
        self.moment = moment
        self.api = api
    }

    /// Starts a follow-up when `snapshot` has no absolute altitude and the capture's altimeter
    /// can still provide one; otherwise nil and the capture keeps its altimeter.
    static func begin(
        from capture: ConnectionCaptureSession,
        snapshot: ConnectionCaptureSession.Snapshot,
        api: ClickAPIClient
    ) -> EncounterAltitudeFollowUp? {
        guard snapshot.altitude?.absoluteAltitudeMeters == nil,
              let feed = capture.handOffAltimeterAwaitingAbsoluteFix() else { return nil }
        let followUp = EncounterAltitudeFollowUp(feed: feed, moment: snapshot.moment, api: api)
        Task { await followUp.run() }
        return followUp
    }

    /// The flow logged encounters on these connections; the altitude is sent for them once known.
    func confirm(connectionIDs ids: [String]) {
        guard !isCancelled, connectionIDs == nil else { return }
        var seen = Set<String>()
        connectionIDs = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.maximumConnections))
    }

    /// The connection did not happen: stop the altimeter and send nothing. Ignored once
    /// confirmed, so closing the result screen never drops a logged encounter's height.
    func cancel() {
        guard connectionIDs == nil else { return }
        isCancelled = true
        feed.stop()
    }

    private func run() async {
        let fixDeadline = moment.addingTimeInterval(AltitudeStabilizer.followUpWindow)
        var reading: AltitudeObservation?
        while !isCancelled, feed.isRunning {
            let now = Date.now
            reading = AltitudeStabilizer.followUp(
                absolute: feed.absoluteSamples, relative: feed.relativeSamples, moment: moment, until: now
            )
            if reading != nil || now >= fixDeadline { break }
            try? await Task.sleep(for: Self.pollInterval)
        }
        feed.stop()
        guard !isCancelled, let reading else { return }

        let confirmDeadline = Date.now.addingTimeInterval(Self.confirmationWindow)
        while !isCancelled, connectionIDs == nil, Date.now < confirmDeadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
        guard !isCancelled, let ids = connectionIDs, !ids.isEmpty,
              let body = Self.body(reading, moment: moment, connectionIDs: ids),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let request = APIRequest(path: "/api/connections/encounter-altitude", method: .post, body: data, requiresAuth: true)
        _ = try? await api.executeRaw(request)
    }

    /// Request body. `connection_moment` uses the same encoding as
    /// `sensor_observation.connection_moment`, which the server matches it against.
    nonisolated static func body(_ reading: AltitudeObservation, moment: Date, connectionIDs: [String]) -> [String: Any]? {
        guard let altitude = reading.absoluteAltitudeMeters, altitude.isFinite, !connectionIDs.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: Any] = [
            "connection_ids": connectionIDs,
            "connection_moment": formatter.string(from: moment),
            "observed_at": formatter.string(from: reading.observedAt),
            "exact_barometric_elevation_m": LocationObservation.rounded(altitude, places: 1)
        ]
        if let accuracy = reading.accuracyMeters, accuracy.isFinite {
            body["barometric_accuracy_m"] = LocationObservation.rounded(accuracy, places: 2)
        }
        if let precision = reading.precisionMeters, precision.isFinite {
            body["barometric_precision_m"] = LocationObservation.rounded(precision, places: 2)
        }
        return body
    }
}
