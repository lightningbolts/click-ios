import Foundation
import UIKit

/// One event Click Drop as the server shows it to this viewer (spec F1). `previewURL` is always the
/// pixelated rendition; the original only comes from `/api/drops/develop` after the reveal.
public struct EventDrop: Identifiable, Sendable, Equatable {
    public let id: String
    public let userID: String
    public let userName: String
    public let avatarURL: String?
    public let isMine: Bool
    public let createdAt: Date?
    public let revealAt: Date?
    public let filterSeed: Int
    public let width: Int?
    public let height: Int?
    public let previewURL: URL?

    var look: ClickDropFilter { .recapLook(seed: filterSeed) }

    static func parse(_ row: [String: Any]) -> EventDrop? {
        guard let id = JSONFields.string(row["id"]) else { return nil }
        let user = JSONFields.dictionary(row["user"]) ?? [:]
        return EventDrop(
            id: id,
            userID: JSONFields.string(user["id"]) ?? "",
            userName: JSONFields.string(user["name"]) ?? "Someone",
            avatarURL: JSONFields.string(user["avatar_url"]),
            isMine: JSONFields.bool(row["is_mine"]) ?? false,
            createdAt: JSONFields.date(row["created_at"]),
            revealAt: JSONFields.date(row["reveal_at"]),
            filterSeed: JSONFields.int(row["filter_seed"]) ?? 0,
            width: JSONFields.int(row["width"]),
            height: JSONFields.int(row["height"]),
            previewURL: JSONFields.string(row["preview_url"]).flatMap(URL.init(string:))
        )
    }
}

/// An event's drops for this viewer: timing, what they may do, and what they may see.
public struct EventDropsState: Sendable, Equatable {
    public enum Phase: String, Sendable { case before, open, developing, revealed }
    /// participant: was there (or hosted); absentee: RSVP'd but never checked in ("What you missed").
    public enum Access: String, Sendable { case participant, absentee, none }

    public let phase: Phase
    public let opensAt: Date?
    public let closesAt: Date?
    public let revealAt: Date?
    public let eventTitle: String
    public let access: Access
    public let canPost: Bool
    public let remaining: Int
    public let showToAbsentees: Bool
    public let drops: [EventDrop]

    public var myDrops: [EventDrop] { drops.filter(\.isMine) }

    static func parse(_ root: [String: Any]) -> EventDropsState {
        EventDropsState(
            phase: JSONFields.string(root["state"]).flatMap(Phase.init(rawValue:)) ?? .before,
            opensAt: JSONFields.date(root["opens_at"]),
            closesAt: JSONFields.date(root["closes_at"]),
            revealAt: JSONFields.date(root["reveal_at"]),
            eventTitle: JSONFields.string(root["event_title"]) ?? "Event",
            access: JSONFields.string(root["access"]).flatMap(Access.init(rawValue:)) ?? .none,
            canPost: JSONFields.bool(root["can_post"]) ?? false,
            remaining: JSONFields.int(root["remaining"]) ?? 0,
            showToAbsentees: JSONFields.bool(root["show_to_absentees"]) ?? true,
            drops: JSONFields.rows(root["drops"]).compactMap(EventDrop.parse)
        )
    }
}

/// Why posting was refused, in plain words.
public enum EventDropPostError: Error, Equatable, LocalizedError {
    case notAllowedNow, capReached, invalidPhoto

    public var errorDescription: String? {
        switch self {
        case .notAllowedNow: "Drops can only be added while you're checked in, until midnight after the event."
        case .capReached: "You've added all your drops for this event."
        case .invalidPhoto: "That photo couldn't be used. Try another."
        }
    }
}

extension BeaconRepository {
    public func eventDrops(beaconID: String) async throws -> EventDropsState {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/drops"))
        return EventDropsState.parse(try JSONFields.object(data))
    }

    /// Posts one drop: the natural photo and its pixelated preview. Retrying with the same
    /// `clientDropID` returns the drop already made, so a failed upload is always safe to retry.
    public func postEventDrop(beaconID: String, clientDropID: UUID, jpeg: Data, showToAbsentees: Bool?) async throws -> EventDrop {
        guard let preview = ClickDropPixelation.previewJPEG(from: jpeg), let image = UIImage(data: jpeg) else {
            throw EventDropPostError.invalidPhoto
        }
        var body: [String: Any] = [
            "client_drop_id": clientDropID.uuidString.lowercased(),
            "mime_type": "image/jpeg",
            "original_b64": jpeg.base64EncodedString(),
            "preview_b64": preview.base64EncodedString(),
            "width": Int(image.size.width * image.scale),
            "height": Int(image.size.height * image.scale)
        ]
        if let showToAbsentees { body["show_to_absentees"] = showToAbsentees }
        do {
            let (data, _) = try await api.executeRaw(APIRequest(
                path: "/api/beacons/\(beaconID)/drops",
                method: .post,
                body: try JSONSerialization.data(withJSONObject: body),
                idempotent: true
            ))
            guard let drop = JSONFields.dictionary(try JSONFields.object(data)["drop"]).flatMap(EventDrop.parse) else {
                throw APIError.decoding
            }
            return drop
        } catch APIError.forbidden {
            throw EventDropPostError.notAllowedNow
        } catch APIError.conflict {
            throw EventDropPostError.capReached
        }
    }

    public func deleteEventDrop(beaconID: String, dropID: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/drops/\(dropID)", method: .delete, idempotent: true))
    }

    public func setEventDropsShownToAbsentees(beaconID: String, _ shown: Bool) async throws {
        _ = try await api.executeRaw(APIRequest(
            path: "/api/beacons/\(beaconID)/drops/settings",
            method: .put,
            body: try JSONSerialization.data(withJSONObject: ["show_to_absentees": shown]),
            idempotent: true
        ))
    }

    /// A quiet report on any drop (moderation only; never shown to anyone).
    public func reportDrop(_ ref: ClickDropRef, reason: String) async throws {
        _ = try await api.executeRaw(APIRequest(
            path: "/api/drops/report",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: ["kind": ref.kind.rawValue, "id": ref.id, "reason": reason])
        ))
    }
}

// MARK: - Event history (spec F2)

public struct PastEvent: Identifiable, Sendable, Equatable {
    public struct Relation: Sendable, Equatable {
        public let went: Bool
        public let rsvpd: Bool
        public let saved: Bool
        public let hosted: Bool
    }

    public enum Recap: Sendable, Equatable {
        case developing(revealAt: Date?)
        case ready
    }

    public var id: String { beaconID }
    public let beaconID: String
    public let title: String
    public let startsAt: Date?
    public let endsAt: Date?
    public let locationName: String?
    public let imageURL: String?
    public let relation: Relation?
    public let recap: Recap?

    static func parse(_ row: [String: Any]) -> PastEvent? {
        guard let id = JSONFields.string(row["beacon_id"]) else { return nil }
        let relation = JSONFields.dictionary(row["relation"]).map {
            Relation(went: JSONFields.bool($0["went"]) ?? false, rsvpd: JSONFields.bool($0["rsvpd"]) ?? false,
                     saved: JSONFields.bool($0["saved"]) ?? false, hosted: JSONFields.bool($0["hosted"]) ?? false)
        }
        let recap = JSONFields.dictionary(row["recap"]).map { recap -> Recap in
            JSONFields.string(recap["state"]) == "ready" ? .ready : .developing(revealAt: JSONFields.date(recap["reveal_at"]))
        }
        return PastEvent(beaconID: id, title: JSONFields.string(row["title"]) ?? "Event",
                         startsAt: JSONFields.date(row["starts_at"]), endsAt: JSONFields.date(row["ends_at"]),
                         locationName: JSONFields.string(row["location_name"]), imageURL: JSONFields.string(row["image_url"]),
                         relation: relation, recap: recap)
    }
}

/// One entry in your History: an event you were part of, a beacon you dropped / reacted to /
/// confirmed, or a hangout you logged (`GET /api/me/history`).
public struct HistoryItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case event, beacon, hangout }

    public let kind: Kind
    public let id: String
    public let title: String
    public let detail: String
    public let at: Date?
    public let place: String?
    public let imageURL: String?
    public let beaconID: String?
    public let beaconType: String?
    public let connectionID: String?
    public let peerID: String?
    public let peerName: String?
    public let peerAvatarURL: String?
    public let recap: PastEvent.Recap?

    static func parse(_ row: [String: Any]) -> HistoryItem? {
        guard let kind = JSONFields.string(row["kind"]).flatMap(Kind.init(rawValue:)), let id = JSONFields.string(row["id"]) else { return nil }
        let peer = JSONFields.dictionary(row["peer"])
        let recap = JSONFields.dictionary(row["recap"]).map { recap -> PastEvent.Recap in
            JSONFields.string(recap["state"]) == "ready" ? .ready : .developing(revealAt: JSONFields.date(recap["reveal_at"]))
        }
        return HistoryItem(kind: kind, id: id, title: JSONFields.string(row["title"]) ?? "", detail: JSONFields.string(row["detail"]) ?? "",
                           at: JSONFields.date(row["at"]), place: JSONFields.string(row["place"]), imageURL: JSONFields.string(row["image_url"]),
                           beaconID: JSONFields.string(row["beacon_id"]), beaconType: JSONFields.string(row["beacon_type"]),
                           connectionID: JSONFields.string(row["connection_id"]), peerID: peer.flatMap { JSONFields.string($0["id"]) },
                           peerName: peer.flatMap { JSONFields.string($0["name"]) }, peerAvatarURL: peer.flatMap { JSONFields.string($0["avatar_url"]) },
                           recap: recap)
    }
}

public enum HistoryFilter: String, CaseIterable, Sendable, Identifiable {
    case all, events, beacons, hangouts, saved

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: "All"
        case .events: "Events"
        case .beacons: "Beacons"
        case .hangouts: "Hangouts"
        case .saved: "Saved"
        }
    }
}

extension BeaconRepository {
    /// Your history (private to you), newest first. `.saved` is served by Saved events instead.
    public func history(_ filter: HistoryFilter, cursor: String?) async throws -> (items: [HistoryItem], nextCursor: String?) {
        var query = [URLQueryItem(name: "kind", value: filter == .saved ? "all" : filter.rawValue)]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/me/history", queryItems: query))
        let root = try JSONFields.object(data)
        return (JSONFields.rows(root["items"]).compactMap(HistoryItem.parse), JSONFields.string(root["next_cursor"]))
    }

    /// The one Home recap card (an event you were at in the last ~48 h), if any.
    public func eventRecapCard() async throws -> PastEvent? {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/me/event-history/recap-card"))
        return JSONFields.dictionary(try JSONFields.object(data)["card"]).flatMap(PastEvent.parse)
    }

    /// Past events you and this person both checked in to — never their full attendance.
    public func eventsTogether(userID: String) async throws -> [PastEvent] {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/users/\(userID)/events-together"))
        return JSONFields.rows(try JSONFields.object(data)["events"]).compactMap(PastEvent.parse)
    }
}
