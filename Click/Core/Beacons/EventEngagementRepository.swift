import Foundation

/// The viewer's RSVP state (`GET /api/beacons/{id}/rsvp`).
public struct RSVPState: Equatable, Sendable {
    public enum Request: String, Sendable {
        case pending, approved, denied, waitlisted
    }

    public let isGoing: Bool
    public let request: Request?
    public let count: Int
}

/// Engagement state shared by every entry point (`GET /api/beacons/{id}/engagement`).
public struct EventEngagement: Equatable, Sendable {
    public var bookmarked: Bool
    public var checkedIn: Bool
    public var checkInCount: Int
}

public struct DirectoryAttendee: Identifiable, Equatable, Sendable {
    public enum Relationship: String, Sendable {
        case `self`, connection, mutual, stranger
    }

    public let userID: String
    public let name: String
    public let avatarURL: String?
    public let sharedInterests: [String]
    public let relationship: Relationship
    public let mutualNames: [String]
    public let mutualCount: Int
    public let signedUpAt: Date?

    public var id: String { userID }
    public var initials: String { Phase3Repository.initials(from: name) }
}

public struct EventDirectory: Equatable, Sendable {
    public let attendees: [DirectoryAttendee]
    public let mutualsUnlocked: Bool
}

/// Server-reported check-in outcomes (spec §56.4). The server owns the geofence.
public enum CheckInError: Error, LocalizedError, Equatable {
    case locationRequired
    case tooFar
    case notOpenYet
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .locationRequired: "Turn on location to check in."
        case .tooFar: "Move closer to the event to check in."
        case .notOpenYet: "Check-in opens when the event starts."
        case .failed(let message): message
        }
    }
}

public enum RSVPError: Error, LocalizedError, Equatable {
    case notAllowed
    case full
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed: "RSVP isn't open to you for this event (it may be invite-only or closed)."
        case .full: "This event is full."
        case .failed(let message): message
        }
    }
}

/// Event engagement: RSVP, bookmark, check-in, directory, and creator delete.
public actor EventEngagementRepository {
    private let api: ClickAPIClient

    public init(api: ClickAPIClient) {
        self.api = api
    }

    public func rsvpState(beaconID: String) async throws -> RSVPState {
        let root = try await object("/api/beacons/\(beaconID)/rsvp", .get)
        return RSVPState(
            isGoing: JSONFields.bool(root["current_user_signed_up"]) ?? false,
            request: JSONFields.string(root["request_status"]).flatMap(RSVPState.Request.init(rawValue:)),
            count: JSONFields.int(root["rsvp_count"]) ?? JSONFields.rows(root["attendees"]).count
        )
    }

    /// RSVP or request to join; the response decides between going, pending, and waitlisted.
    public func rsvp(beaconID: String) async throws -> RSVPState.Request? {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["source": "event_detail", "platform": "ios"])
            let root = try await object("/api/beacons/\(beaconID)/rsvp", .post, body: body)
            return JSONFields.string(root["request_status"]).flatMap(RSVPState.Request.init(rawValue:))
        } catch APIError.forbidden {
            throw RSVPError.notAllowed
        } catch APIError.conflict {
            throw RSVPError.full
        }
    }

    public func cancelRSVP(beaconID: String) async throws {
        _ = try await object("/api/beacons/\(beaconID)/rsvp", .delete)
    }

    public func engagement(beaconID: String) async throws -> EventEngagement {
        let root = try await object("/api/beacons/\(beaconID)/engagement", .get)
        return EventEngagement(
            bookmarked: JSONFields.bool(root["bookmarked"]) ?? false,
            checkedIn: JSONFields.bool(root["checked_in"]) ?? false,
            checkInCount: JSONFields.int(root["check_in_count"]) ?? 0
        )
    }

    /// Returns the server's bookmark value (the only value the UI may show as saved).
    public func setBookmark(beaconID: String, bookmarked: Bool) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["bookmarked": bookmarked])
        let root = try await object("/api/beacons/\(beaconID)/bookmark", .put, body: body)
        guard let confirmed = JSONFields.bool(root["bookmarked"]) else { throw APIError.decoding }
        return confirmed
    }

    public func checkIn(beaconID: String, latitude: Double?, longitude: Double?, accuracy: Double?) async throws -> Int {
        var payload: [String: Any] = ["source": "event_detail", "platform": "ios"]
        if let latitude, let longitude {
            payload["latitude"] = latitude
            payload["longitude"] = longitude
            if let accuracy { payload["accuracy_meters"] = accuracy }
        }
        do {
            let root = try await object("/api/beacons/\(beaconID)/check-in", .post, body: try JSONSerialization.data(withJSONObject: payload))
            return JSONFields.int(root["check_in_count"]) ?? 0
        } catch {
            throw Self.checkInError(error)
        }
    }

    public func checkOut(beaconID: String) async throws {
        _ = try await object("/api/beacons/\(beaconID)/check-in", .delete)
    }

    public func directory(beaconID: String) async throws -> EventDirectory {
        let root = try await object("/api/beacons/\(beaconID)/attendees/directory", .get)
        guard root["attendees"] != nil else { throw APIError.decoding }
        let attendees = JSONFields.rows(root["attendees"]).compactMap { row -> DirectoryAttendee? in
            guard let id = JSONFields.string(row["user_id"]) else { return nil }
            let mutuals = JSONFields.rows(row["mutual_via"]).compactMap { JSONFields.string($0["name"]) }
            return DirectoryAttendee(
                userID: id,
                name: JSONFields.string(row["name"]) ?? "Attendee",
                avatarURL: JSONFields.string(row["avatar_url"]),
                sharedInterests: JSONFields.stringArray(row["shared_interests"]),
                relationship: JSONFields.string(row["relationship"]).flatMap(DirectoryAttendee.Relationship.init(rawValue:)) ?? .stranger,
                mutualNames: mutuals,
                mutualCount: JSONFields.int(row["mutual_connection_count"]) ?? mutuals.count,
                signedUpAt: JSONFields.date(row["signed_up_at"])
            )
        }
        return EventDirectory(attendees: attendees, mutualsUnlocked: JSONFields.bool(root["mutuals_section_unlocked"]) ?? false)
    }

    /// Creator-only (the server enforces it).
    // MARK: - Guest list (§58, event managers only)

    public func guestList(beaconID: String) async throws -> GuestListStatus {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/guest-list"))
        return GuestListStatus(root: try JSONFields.object(data))
    }

    /// Pasted CSV or one-per-line emails / @handles (server parses both, max 2 000).
    public func uploadGuestList(beaconID: String, text: String) async throws -> GuestListStatus {
        let body = try JSONSerialization.data(withJSONObject: ["source": "csv", "csv_text": text])
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/guest-list", method: .post, body: body))
        return GuestListStatus(root: try JSONFields.object(data))
    }

    public func rematchGuestList(beaconID: String) async throws -> GuestListStatus {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/guest-list/match", method: .post, body: Data("{}".utf8)))
        return GuestListStatus(root: try JSONFields.object(data))
    }

    public func deleteBeacon(id: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/beacons/\(id)", method: .delete))
    }

    static func checkInError(_ error: Error) -> Error {
        switch error as? APIError {
        case .validation: CheckInError.locationRequired
        case .forbidden: CheckInError.tooFar
        case .conflict: CheckInError.notOpenYet
        case .some(let api): CheckInError.failed(api.userFacingMessage)
        case nil: error
        }
    }

    private func object(_ path: String, _ method: HTTPMethod, body: Data? = nil) async throws -> [String: Any] {
        let (data, _) = try await api.executeRaw(APIRequest(path: path, method: method, body: body))
        return try JSONFields.object(data)
    }
}

/// Organizer view of an imported guest list (emails arrive truncated from the server).
public struct GuestListStatus: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let matched: Bool
    }

    public let uploaded: Int
    public let matched: Int
    public let teasers: Int
    public let entries: [Entry]

    init(root: [String: Any]) {
        uploaded = JSONFields.int(root["uploaded"]) ?? 0
        matched = JSONFields.int(root["matched"]) ?? 0
        teasers = JSONFields.int(root["teasers"]) ?? 0
        entries = JSONFields.rows(root["entries"]).compactMap { row in
            guard let id = JSONFields.string(row["id"]) else { return nil }
            let label = JSONFields.string(row["email_truncated"]) ?? JSONFields.string(row["instagram_handle"]).map { "@" + $0 } ?? "Guest"
            return Entry(id: id, label: label, matched: JSONFields.bool(row["matched"]) ?? false)
        }
    }
}
