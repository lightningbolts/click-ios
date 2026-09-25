import Foundation

/// Evidence captured during one tap. Tokens only — never raw audio.
public struct ProximityEvidence: Codable, Equatable, Sendable {
    public let myToken: String
    public let heardTokens: [String]
    public let detectedDevices: [String]
    public let latitude: Double?
    public let longitude: Double?
    public let simulatorMock: Bool
    /// Opt-in encounter context sent with the handshake (KMP body keys); the server stores it
    /// on the encounter it creates.
    public var sensor = EncounterSensorContext()

    var peerTokens: [String] { Array(Set(heardTokens + detectedDevices)).sorted() }

    /// `POST /api/connections/proximity` body, field-for-field with KMP `ProximityHandshakePostBody`.
    var body: [String: Any] {
        var body: [String: Any] = [
            "my_token": myToken,
            "tokens": peerTokens,
            "heard_tokens": heardTokens,
            "detected_devices": detectedDevices,
            "timezone_offset_minutes": TimeZone.current.secondsFromGMT() / 60,
            "client_context_first": true
        ]
        if let latitude, let longitude {
            body["latitude"] = latitude
            body["longitude"] = longitude
        }
        if simulatorMock { body["simulator_mock"] = true }
        if let meters = sensor.barometricElevationMeters { body["exact_barometric_elevation_m"] = meters }
        if let level = sensor.noiseLevel { body["noise_level"] = level }
        if let decibels = sensor.noiseDecibels { body["exact_noise_level_db"] = decibels }
        return body
    }
}

/// A person returned by the server for a tap.
public struct ProximityPeer: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let avatarURL: String?
    public let connectionID: String?
    public let isNewConnection: Bool?

    public var initials: String { Phase3Repository.initials(from: name) }

    static func decode(_ row: [String: Any]) -> ProximityPeer? {
        guard let id = JSONFields.string(row["id"]) else { return nil }
        let first = JSONFields.string(row["first_name"])
        let last = JSONFields.string(row["last_name"])
        let composed = [first, last].compactMap { $0 }.joined(separator: " ")
        return ProximityPeer(
            id: id,
            name: JSONFields.string(row["name"]) ?? (composed.isEmpty ? "Click user" : composed),
            avatarURL: JSONFields.string(row["image"]),
            connectionID: JSONFields.string(row["connection_id"]),
            isNewConnection: JSONFields.bool(row["is_new_connection"])
        )
    }
}

/// A server-confirmed match (the only state that may be shown as "connected").
public struct ProximityMatch: Equatable, Sendable {
    public let connectionID: String?
    public let isNewConnection: Bool
    public let isGroup: Bool
    public let peers: [ProximityPeer]
    public let groupMemberIDs: [String]
    public let encounterLogged: Bool
    /// A reconnect the server declined to log (per-peer `reason: rate_limit_active`, or a
    /// reconnect that logged nothing) — KMP `shouldBlockForRateLimit`.
    public var rateLimited: Bool = false
    /// The encounter row created or updated by this tap, and the Click Drop session end.
    public var encounterID: String? = nil
    public var collaborationEndsAt: Date? = nil

    public var isReconnect: Bool { !isNewConnection }
}

public enum ProximityBindResult: Equatable, Sendable {
    /// Server matched peers and created/updated the connection.
    case matched(ProximityMatch)
    /// First-time 3+ tap: the host must choose people before anything is created.
    case awaitingSelection(pendingID: String, candidates: [ProximityPeer])
    /// Stored server-side; the peer's tap may still arrive.
    case pending(pendingID: String)
    /// The server ignored an empty/invalid tap.
    case ignored
}

/// Server-authoritative Tap to Connect transport (spec §23–§24). The client never decides
/// whether a tap matched.
public actor ProximityRepository {
    private let api: ClickAPIClient
    private let cache: CacheStore

    /// Server host-selection cap (host + 11 peers).
    public static let maxSelectedPeers = 11
    /// Queued offline taps older than the server's pending window are dropped.
    static let queuedHandshakeMaxAge: TimeInterval = 48 * 3600

    public init(api: ClickAPIClient, cache: CacheStore = .shared) {
        self.api = api
        self.cache = cache
    }

    public func bind(_ evidence: ProximityEvidence) async throws -> ProximityBindResult {
        let body = try JSONSerialization.data(withJSONObject: evidence.body)
        do {
            let (data, response) = try await api.executeRaw(
                APIRequest(path: "/api/connections/proximity", method: .post, body: body)
            )
            return try Self.result(data: data, status: response.statusCode)
        } catch APIError.server(let status, _, let message) where status == 503 {
            // Connection creation failed after the tap was stored: recover via GET.
            if let pendingID = Self.pendingID(fromErrorBody: message) {
                return .pending(pendingID: pendingID)
            }
            throw APIError.server(status: status, code: nil, message: nil)
        }
    }

    /// `GET /api/connections/proximity?pending_handshake_id=`.
    public func recover(pendingID: String) async throws -> ProximityBindResult {
        let (data, response) = try await api.executeRaw(APIRequest(
            path: "/api/connections/proximity",
            method: .get,
            queryItems: [URLQueryItem(name: "pending_handshake_id", value: pendingID)]
        ))
        return try Self.result(data: data, status: response.statusCode)
    }

    /// `POST /api/connections/proximity/confirm` after the host picks people.
    public func confirmSelection(pendingID: String, memberIDs: [String]) async throws -> ProximityMatch {
        let members = Array(Array(Set(memberIDs)).sorted().prefix(Self.maxSelectedPeers))
        guard !members.isEmpty else { throw APIError.validation(code: "selection", message: nil) }
        let body = try JSONSerialization.data(withJSONObject: [
            "pending_handshake_id": pendingID,
            "selected_member_ids": members
        ])
        let (data, _) = try await api.executeRaw(
            APIRequest(path: "/api/connections/proximity/confirm", method: .post, body: body)
        )
        guard case .matched(let match) = try Self.result(data: data, status: 200) else {
            throw APIError.decoding
        }
        return match
    }

    // MARK: - Offline queue (spec §69.4)

    private struct QueuedHandshake: Codable {
        let id: UUID
        let createdAt: Date
        let evidence: ProximityEvidence
    }

    /// Persists a tap whose submission failed for connectivity reasons. User-scoped.
    public func enqueue(_ evidence: ProximityEvidence, userID: String) async {
        var queue = await cache.load([QueuedHandshake].self, key: "pending-handshakes", userID: userID) ?? []
        queue.append(QueuedHandshake(id: UUID(), createdAt: .now, evidence: evidence))
        await cache.save(queue, key: "pending-handshakes", userID: userID)
    }

    /// Replays queued taps for this user only. Stops at the first connectivity failure; drops
    /// expired entries and entries the server rejects permanently. Returns confirmed matches.
    public func flushQueue(userID: String) async -> [ProximityMatch] {
        guard var queue = await cache.load([QueuedHandshake].self, key: "pending-handshakes", userID: userID),
              !queue.isEmpty else { return [] }
        var matches: [ProximityMatch] = []
        queue.removeAll { Date.now.timeIntervalSince($0.createdAt) > Self.queuedHandshakeMaxAge }
        while let next = queue.first {
            do {
                if case .matched(let match) = try await bind(next.evidence) { matches.append(match) }
                queue.removeFirst()
            } catch let error where error.isOffline {
                break
            } catch {
                queue.removeFirst()
            }
        }
        await cache.save(queue, key: "pending-handshakes", userID: userID)
        return matches
    }

    // MARK: - Parsing

    static func result(data: Data, status: Int) throws -> ProximityBindResult {
        let root = try JSONFields.object(data)
        if JSONFields.string(root["status"]) == "ignored_empty_payload" || root["ignored_empty_payload"] != nil {
            return .ignored
        }
        if let error = JSONFields.string(root["error"]) {
            throw APIError.validation(code: "proximity", message: error)
        }
        let peers = JSONFields.rows(root["matches"]).compactMap(ProximityPeer.decode)
        if JSONFields.bool(root["awaiting_selection"]) == true, let pendingID = JSONFields.string(root["pending_handshake_id"]) {
            return .awaitingSelection(pendingID: pendingID, candidates: peers)
        }
        if status == 202 {
            guard let pendingID = JSONFields.string(root["pending_handshake_id"]) else { throw APIError.decoding }
            return .pending(pendingID: pendingID)
        }
        let groupIDs = JSONFields.stringArray(JSONFields.dictionary(root["group_clique_candidate"])?["member_user_ids"])
        let matchRows = JSONFields.rows(root["matches"])
        let isNew = JSONFields.bool(root["is_new_connection"]) ?? peers.contains { $0.isNewConnection == true }
        let logged = JSONFields.bool(root["encounter_logged"]) ?? false
        let persistedOnBind = !matchRows.isEmpty && matchRows.allSatisfy { JSONFields.bool($0["encounter_persisted_on_bind"]) == true }
        let rateLimited = matchRows.contains { JSONFields.string($0["reason"]) == "rate_limit_active" }
            || (!isNew && !persistedOnBind && (!logged || matchRows.contains { JSONFields.bool($0["encounter_logged"]) == false }))
        return .matched(ProximityMatch(
            connectionID: JSONFields.string(root["connection_id"]),
            isNewConnection: isNew,
            isGroup: JSONFields.bool(root["is_group"]) ?? false,
            peers: peers,
            groupMemberIDs: groupIDs,
            encounterLogged: logged,
            rateLimited: rateLimited,
            encounterID: JSONFields.string(root["encounter_id"]),
            collaborationEndsAt: JSONFields.date(root["collaboration_ttl"])
        ))
    }

    static func pendingID(fromErrorBody body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8), let root = try? JSONFields.object(data) else { return nil }
        return JSONFields.string(root["pending_handshake_id"])
    }
}
