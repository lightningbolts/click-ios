import Foundation
import Synchronization

/// The viewer's RSVP state (`GET /api/beacons/{id}/rsvp`).
public struct RSVPState: Equatable, Sendable, Codable {
    public enum Request: String, Sendable, Codable {
        case pending, approved, denied, waitlisted
    }

    public let isGoing: Bool
    public let request: Request?
    public let count: Int
}

/// Engagement state shared by every entry point (`GET /api/beacons/{id}/engagement`).
public struct EventEngagement: Equatable, Sendable, Codable {
    public var bookmarked: Bool
    public var checkedIn: Bool
    public var checkInCount: Int
}

/// Your Click Pass for an event (`GET /api/beacons/{id}/pass`): the QR the host scans at the door.
/// The credential never changes for an attendee, so it's kept on the device and shows offline.
public struct ClickPass: Equatable, Sendable, Codable {
    /// The QR payload: the event's public link carrying the pass.
    public let credentialURL: String
    /// "K7P-4QX": under the QR and in Wallet, so the host can tell passes apart.
    public let code: String
    public var checkedInAt: Date?
    public let walletAvailable: Bool
}

/// An event you're hosting or going to (`GET /api/beacons/mine`): Home's Upcoming and the Live
/// Activity read it.
public struct MyEvent: Codable, Equatable, Sendable {
    public let beaconID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let place: String?
    public let isHost: Bool
    public var imageURL: String? = nil
}

/// What a host's scan of a Click Pass found (`POST /api/beacons/{id}/pass/scan`).
public struct PassScan: Equatable, Sendable {
    public enum Result: String, Sendable {
        case checkedIn = "checked_in"
        case alreadyCheckedIn = "already_checked_in"
        case notGoing = "not_going"
        case wrongEvent = "wrong_event"
        case invalid
    }

    public struct Holder: Equatable, Sendable {
        public let userID: String
        public let name: String
        public let avatarURL: String?
    }

    public let result: Result
    public let holder: Holder?
    public let checkedInAt: Date?
    public let checkInCount: Int?
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
    /// The event is over: the people read as who was there.
    public var hasEnded = false
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

    // Synchronously readable, so an event paints its RSVP, saved state and people on its first frame.
    private nonisolated let rsvpCache = MemoryCache<String, RSVPState>()
    private nonisolated let engagementCache = MemoryCache<String, EventEngagement>()
    private nonisolated let directoryCache = MemoryCache<String, EventDirectory>()
    private nonisolated let passCache = MemoryCache<String, ClickPass>()

    // MARK: - Persistence

    /// RSVP and saved/check-in state survive a relaunch (per user), so an event opened right
    /// after a cold start paints its RSVP button on the first frame instead of a blank one.
    private struct Persisted: Codable {
        var rsvp: [String: RSVPState]
        var engagement: [String: EventEngagement]
        /// Optional: files written before passes existed decode without it.
        var passes: [String: ClickPass]?
    }

    private static let persistKey = "events.engagement"
    /// Bounds the file: past this, only this session's entries are kept.
    private static let persistLimit = 400
    private nonisolated let owner = Mutex<String?>(nil)

    /// Reads the signed-in user's saved states on the spot (before the shell's first frame).
    public nonisolated func restore(userID: String) {
        guard owner.withLock({ current in
            defer { current = userID }
            return current != userID
        }) else { return }
        rsvpCache.removeAll()
        engagementCache.removeAll()
        directoryCache.removeAll()
        passCache.removeAll()
        guard let stored = LocalStore.shared.load(Persisted.self, key: Self.persistKey, userID: userID)?.value else { return }
        rsvpCache.fill(stored.rsvp)
        engagementCache.fill(stored.engagement)
        passCache.fill(stored.passes ?? [:])
    }

    /// Sign-out: nothing of one account's events is shown to the next.
    public nonisolated func clear() {
        owner.withLock { $0 = nil }
        rsvpCache.removeAll()
        engagementCache.removeAll()
        directoryCache.removeAll()
        passCache.removeAll()
    }

    private func persist() {
        guard let userID = owner.withLock({ $0 }) else { return }
        var rsvp = rsvpCache.all
        var engagement = engagementCache.all
        if rsvp.count + engagement.count > Self.persistLimit * 2 {
            rsvp = Dictionary(uniqueKeysWithValues: rsvp.prefix(Self.persistLimit).map { ($0.key, $0.value) })
            engagement = Dictionary(uniqueKeysWithValues: engagement.prefix(Self.persistLimit).map { ($0.key, $0.value) })
        }
        LocalStore.shared.save(Persisted(rsvp: rsvp, engagement: engagement, passes: passCache.all), key: Self.persistKey, userID: userID)
    }

    /// RSVP and saved state for events likely to be opened next (Home's saved events), loaded
    /// ahead so their pages never wait on it. Only events not known yet; failures stay quiet.
    public func warm(beaconIDs: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in Set(beaconIDs) where rsvpCache[id] == nil {
                group.addTask {
                    async let rsvp = try? self.rsvpState(beaconID: id)
                    async let engagement = try? self.engagement(beaconID: id)
                    _ = await (rsvp, engagement)
                }
            }
        }
    }

    public nonisolated func cachedRSVP(beaconID: String) -> RSVPState? {
        rsvpCache[beaconID]
    }

    public nonisolated func cachedEngagement(beaconID: String) -> EventEngagement? {
        engagementCache[beaconID]
    }

    public nonisolated func cachedDirectory(beaconID: String) -> EventDirectory? {
        directoryCache[beaconID]
    }

    public func rsvpState(beaconID: String) async throws -> RSVPState {
        let root = try await object("/api/beacons/\(beaconID)/rsvp", .get)
        let state = RSVPState(
            isGoing: JSONFields.bool(root["current_user_signed_up"]) ?? false,
            request: JSONFields.string(root["request_status"]).flatMap(RSVPState.Request.init(rawValue:)),
            count: JSONFields.int(root["rsvp_count"]) ?? JSONFields.rows(root["attendees"]).count
        )
        rsvpCache[beaconID] = state
        persist()
        return state
    }

    /// RSVP or request to join; the response decides between going, pending, and waitlisted.
    public func rsvp(beaconID: String) async throws -> RSVPState.Request? {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["source": "event_detail", "platform": "ios"])
            let root = try await object("/api/beacons/\(beaconID)/rsvp", .post, body: body)
            let req = JSONFields.string(root["request_status"]).flatMap(RSVPState.Request.init(rawValue:))
            let prevCount = rsvpCache[beaconID]?.count ?? 0
            rsvpCache[beaconID] = RSVPState(isGoing: req == nil, request: req, count: prevCount + 1)
            persist()
            return req
        } catch APIError.forbidden {
            throw RSVPError.notAllowed
        } catch APIError.conflict {
            throw RSVPError.full
        }
    }

    public func cancelRSVP(beaconID: String) async throws {
        _ = try await object("/api/beacons/\(beaconID)/rsvp", .delete)
        let prevCount = rsvpCache[beaconID]?.count ?? 1
        rsvpCache[beaconID] = RSVPState(isGoing: false, request: nil, count: max(0, prevCount - 1))
        // The pass is void at the door from now on; don't keep showing it.
        passCache[beaconID] = nil
        persist()
    }

    // MARK: - Click Pass

    public nonisolated func cachedPass(beaconID: String) -> ClickPass? {
        passCache[beaconID]
    }

    /// Throws `APIError.forbidden` when you aren't going (no pass yet, or the RSVP was cancelled).
    public func pass(beaconID: String) async throws -> ClickPass {
        do {
            let root = try await object("/api/beacons/\(beaconID)/pass", .get)
            guard let url = JSONFields.string(root["credential_url"]), let code = JSONFields.string(root["code"]) else {
                throw APIError.decoding
            }
            let pass = ClickPass(credentialURL: url, code: code, checkedInAt: JSONFields.date(root["checked_in_at"]),
                                 walletAvailable: JSONFields.bool(root["wallet_available"]) ?? false)
            passCache[beaconID] = pass
            persist()
            return pass
        } catch APIError.forbidden {
            passCache[beaconID] = nil
            persist()
            throw APIError.forbidden
        }
    }

    /// Events you're hosting or going to that have a schedule (newest RSVPs first, up to 50).
    public func myEvents() async throws -> [MyEvent] {
        let root = try await object("/api/beacons/mine", .get)
        return JSONFields.rows(root["events"]).compactMap { row in
            guard let id = JSONFields.string(row["beacon_id"]),
                  let start = JSONFields.date(row["event_start_at"]),
                  let end = JSONFields.date(row["event_end_at"]), end > start else { return nil }
            return MyEvent(beaconID: id, title: JSONFields.string(row["title"]) ?? "Event", start: start, end: end,
                           place: JSONFields.string(row["location_name"]), isHost: JSONFields.string(row["role"]) == "creator",
                           imageURL: JSONFields.string(row["image_url"]))
        }
    }

    /// The signed Apple Wallet pass (`.pkpass` bytes).
    public func walletPass(beaconID: String) async throws -> Data {
        try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/pass/wallet")).0
    }

    /// Host only (the server checks): checks the pass's holder in, or says why not.
    public func scanPass(beaconID: String, credential: String) async throws -> PassScan {
        let body = try JSONSerialization.data(withJSONObject: ["credential": credential])
        let root = try await object("/api/beacons/\(beaconID)/pass/scan", .post, body: body)
        guard let result = JSONFields.string(root["result"]).flatMap(PassScan.Result.init(rawValue:)) else { throw APIError.decoding }
        let holder = JSONFields.dictionary(root["attendee"]).flatMap { row -> PassScan.Holder? in
            guard let id = JSONFields.string(row["user_id"]) else { return nil }
            return PassScan.Holder(userID: id, name: JSONFields.string(row["name"]) ?? "Guest", avatarURL: JSONFields.string(row["avatar_url"]))
        }
        return PassScan(result: result, holder: holder, checkedInAt: JSONFields.date(root["checked_in_at"]),
                        checkInCount: JSONFields.int(root["check_in_count"]))
    }

    public func engagement(beaconID: String) async throws -> EventEngagement {
        let root = try await object("/api/beacons/\(beaconID)/engagement", .get)
        let eng = EventEngagement(
            bookmarked: JSONFields.bool(root["bookmarked"]) ?? false,
            checkedIn: JSONFields.bool(root["checked_in"]) ?? false,
            checkInCount: JSONFields.int(root["check_in_count"]) ?? 0
        )
        engagementCache[beaconID] = eng
        persist()
        return eng
    }

    /// Returns the server's bookmark value (the only value the UI may show as saved).
    public func setBookmark(beaconID: String, bookmarked: Bool) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["bookmarked": bookmarked])
        let root = try await object("/api/beacons/\(beaconID)/bookmark", .put, body: body)
        guard let confirmed = JSONFields.bool(root["bookmarked"]) else { throw APIError.decoding }
        if let existing = engagementCache[beaconID] {
            engagementCache[beaconID] = EventEngagement(bookmarked: confirmed, checkedIn: existing.checkedIn, checkInCount: existing.checkInCount)
        } else {
            engagementCache[beaconID] = EventEngagement(bookmarked: confirmed, checkedIn: false, checkInCount: 0)
        }
        persist()
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
            let count = JSONFields.int(root["check_in_count"]) ?? 0
            if let existing = engagementCache[beaconID] {
                engagementCache[beaconID] = EventEngagement(bookmarked: existing.bookmarked, checkedIn: true, checkInCount: count)
                persist()
            }
            return count
        } catch {
            throw Self.checkInError(error)
        }
    }

    public func checkOut(beaconID: String) async throws {
        _ = try await object("/api/beacons/\(beaconID)/check-in", .delete)
        if let existing = engagementCache[beaconID] {
            engagementCache[beaconID] = EventEngagement(bookmarked: existing.bookmarked, checkedIn: false, checkInCount: max(0, existing.checkInCount - 1))
            persist()
        }
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
        let dir = EventDirectory(attendees: attendees, mutualsUnlocked: JSONFields.bool(root["mutuals_section_unlocked"]) ?? false,
                                 hasEnded: JSONFields.bool(root["event_ended"]) ?? false)
        directoryCache[beaconID] = dir
        return dir
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
