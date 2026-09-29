import CoreLocation
import Foundation

/// Crowd upkeep for alert (hazard) beacons (spec F4, flag `alert_confirmations`): people nearby
/// say "Still here" (keeps it up) or "Cleared" (enough of them take it down for everyone).
public enum AlertVote: String, Sendable {
    case stillHere = "still_here"
    case cleared
}

public struct AlertConfirmationState: Sendable, Equatable {
    public enum Phase: String, Sendable { case active, cleared, expired }

    public let phase: Phase
    public let expiresAt: Date?
    /// When someone last said it's still there — the only public signal (no counts).
    public let lastStillHereAt: Date?
    public let myVote: AlertVote?
    public let isCreator: Bool
    public let radiusMeters: Int

    static func parse(_ root: [String: Any]) -> AlertConfirmationState {
        let myVote = JSONFields.dictionary(root["my_vote"]).flatMap { JSONFields.string($0["status"]) }.flatMap(AlertVote.init(rawValue:))
        return AlertConfirmationState(
            phase: JSONFields.string(root["state"]).flatMap(Phase.init(rawValue:)) ?? .expired,
            expiresAt: JSONFields.date(root["expires_at"]),
            lastStillHereAt: JSONFields.date(root["last_still_here_at"]),
            myVote: myVote,
            isCreator: JSONFields.bool(root["is_creator"]) ?? false,
            radiusMeters: JSONFields.int(root["radius_meters"]) ?? 300
        )
    }
}

/// Why the server turned a vote down, in words for the person holding the phone.
public enum AlertVoteRejection: Error, Equatable, LocalizedError {
    case tooFar, alreadyVoted, ended, needsLocation

    public var errorDescription: String? {
        switch self {
        case .tooFar: "You need to be near this alert to confirm it."
        case .alreadyVoted: "You've already confirmed this alert recently."
        case .ended: "This alert has already ended."
        case .needsLocation: "Your location is needed to confirm an alert."
        }
    }

    static func from(_ error: Error) -> AlertVoteRejection? {
        switch error as? APIError {
        case .forbidden?: .tooFar
        case .conflict?: .alreadyVoted
        case .notFound?, .server(410, _, _)?: .ended
        case .validation?: .needsLocation
        default: nil
        }
    }
}

extension BeaconRepository {
    public func alertState(beaconID: String) async throws -> AlertConfirmationState {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/confirm"))
        return AlertConfirmationState.parse(try JSONFields.object(data))
    }

    /// Returns the alert's new expiry (now, when this vote cleared it). Throws
    /// `AlertVoteRejection` for the server's expected refusals.
    @discardableResult
    public func confirmAlert(beaconID: String, vote: AlertVote, at coordinate: CLLocationCoordinate2D?) async throws -> Date? {
        var body: [String: Any] = ["status": vote.rawValue]
        if let coordinate {
            body["lat"] = coordinate.latitude
            body["lng"] = coordinate.longitude
        }
        do {
            let (data, _) = try await api.executeRaw(APIRequest(
                path: "/api/beacons/\(beaconID)/confirm",
                method: .post,
                body: try JSONSerialization.data(withJSONObject: body)
            ))
            return JSONFields.date(try JSONFields.object(data)["expires_at"])
        } catch {
            throw AlertVoteRejection.from(error) ?? error
        }
    }

    /// A quiet report to moderation — never shown to anyone, not a vote.
    public func report(beaconID: String, reason: String) async throws {
        _ = try await api.executeRaw(APIRequest(
            path: "/api/beacons/\(beaconID)/report",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: ["reason": reason])
        ))
    }
}
