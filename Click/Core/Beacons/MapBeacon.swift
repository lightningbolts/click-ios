import CoreLocation
import Foundation

/// Canonical current beacon kinds (spec §52.1), with a compatibility path for the values the
/// backend actually stores.
///
/// `click-web`'s `normalizeMobileKindToBeaconType` persists mobile `social_vibe` as `recreation`
/// and mobile `other` as `hobby`, and older rows use `hazard_utility`. Those are mapped back here
/// so native never invents extra kinds (recreation/transit/swag/…) as first-class UI categories.
public enum BeaconKind: String, Codable, CaseIterable, Hashable, Sendable {
    case soundtrack
    case sos
    case hazard
    case utility
    case study
    case socialVibe = "social_vibe"
    case event
    case other

    public init(raw: String?) {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let exact = BeaconKind(rawValue: value) {
            self = exact
            return
        }
        switch value {
        case "hazard_utility": self = .hazard
        case "recreation": self = .socialVibe
        case "hobby", "swag", "capacity", "transit", "scavenger", "": self = .other
        default:
            if value.contains("sound") || value == "music" { self = .soundtrack }
            else if value.contains("sos") || value.contains("emergency") { self = .sos }
            else if value.contains("danger") { self = .hazard }
            else if value.contains("util") || value.contains("amenity") { self = .utility }
            else if value.contains("study") { self = .study }
            else if value.contains("social") || value.contains("vibe") { self = .socialVibe }
            else if value.contains("activity") { self = .event }
            else { self = .other }
        }
    }

    public var label: String {
        switch self {
        case .soundtrack: "Soundtrack"
        case .sos: "SOS"
        case .hazard: "Hazard"
        case .utility: "Utility"
        case .study: "Study"
        case .socialVibe: "Social"
        case .event: "Event"
        case .other: "Other"
        }
    }

    /// Plural label for discovery counts ("3 Events").
    public var pluralLabel: String {
        switch self {
        case .soundtrack: "Soundtracks"
        case .sos: "SOS"
        case .hazard: "Hazards"
        case .utility: "Utilities"
        case .study: "Study spots"
        case .socialVibe: "Social"
        case .event: "Events"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .soundtrack: "music.note"
        case .sos: "sos"
        case .hazard: "exclamationmark.triangle.fill"
        case .utility: "wrench.adjustable.fill"
        case .study: "book.fill"
        case .socialVibe: "person.2.fill"
        case .event: "calendar"
        case .other: "mappin"
        }
    }
}

/// An event's scheduled window. Events without a valid window are not treated as scheduled.
public struct EventSchedule: Codable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init?(start: Date?, end: Date?) {
        guard let start, let end, end > start else { return nil }
        self.start = start
        self.end = end
    }

    public func isLive(at now: Date = .now) -> Bool { now >= start && now < end }
    public func isEnded(at now: Date = .now) -> Bool { now >= end }
    public func startsToday(at now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.isDate(start, inSameDayAs: now)
    }
}

/// A map beacon as the native client understands it. Metadata is decoded defensively because
/// historical rows use legacy key names (spec §52.3).
public struct MapBeacon: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: BeaconKind
    /// The stored backend `beacon_type`, kept for diagnostics and compatibility writes.
    public let rawType: String
    public let creatorID: String
    public let creatorName: String?
    public let showCreatorName: Bool
    public let latitude: Double
    public let longitude: Double
    public let title: String
    public let description: String?
    public let locationName: String?
    public let formattedAddress: String?
    public let imageURL: String?
    public let schedule: EventSchedule?
    public let eventCategories: [String]
    public let createdAt: Date?
    public let expiresAt: Date?
    public let hubID: String?
    public let musicURL: String?
    public let artistName: String?
    public let venueScale: String?
    /// Event listing policy (web `parseEventListingOptions`); optional for cached rows.
    public var rsvpEnabled: Bool? = nil
    public var approvalRequired: Bool? = nil
    public var capacity: Int? = nil
    public var visibility: String? = nil
    /// Soundtrack: iTunes 30 s preview and track name (server/device enrichment).
    public var previewURL: String? = nil
    public var trackName: String? = nil
    public var albumArtURL: String? = nil

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var isEvent: Bool { kind == .event }

    /// Discovery visibility: events use their schedule end; other beacons their TTL.
    public func isActive(at now: Date = .now) -> Bool {
        if let schedule, kind == .event { return !schedule.isEnded(at: now) }
        guard let expiresAt else { return true }
        return expiresAt > now
    }

    /// The name shown for the creator, honoring the creator's display choice.
    public var visibleCreatorName: String? {
        showCreatorName ? creatorName : nil
    }

    /// Maps one `/api/beacons` row. Returns `nil` for rows missing identity or coordinates.
    static func decode(_ row: [String: Any]) -> MapBeacon? {
        guard
            let id = JSONFields.string(row["id"]),
            let latitude = JSONFields.double(row["lat"]),
            let longitude = JSONFields.double(row["lng"] ?? row["lon"])
        else { return nil }

        let rawType = JSONFields.string(row["beacon_type"]) ?? JSONFields.string(row["kind"]) ?? "other"
        let kind = BeaconKind(raw: rawType)
        let meta = JSONFields.dictionary(row["metadata"]) ?? [:]

        return MapBeacon(
            id: id,
            kind: kind,
            rawType: rawType,
            creatorID: JSONFields.string(row["creator_id"]) ?? "",
            creatorName: JSONFields.string(row["creator_name"]),
            showCreatorName: JSONFields.bool(row["show_creator_name"]) ?? false,
            latitude: latitude,
            longitude: longitude,
            title: displayTitle(kind: kind, meta: meta),
            description: JSONFields.string(meta, "description", "text", "message", "body"),
            locationName: JSONFields.string(meta, "location_name", "place_name", "venue_name"),
            formattedAddress: JSONFields.string(meta, "formatted_address", "address", "display_address"),
            // An uploaded photo wins; otherwise a soundtrack shows its album art (upscaled from
            // iTunes' 100 px thumbnail so the hero isn't blurry).
            imageURL: JSONFields.string(meta, "image_url", "cover_url")
                ?? SoundtrackResolver.artwork(JSONFields.string(meta, "album_art_url", "artworkUrl100", "artwork_url")),
            schedule: EventSchedule(
                start: JSONFields.date(meta["event_start_at"] ?? meta["eventStartAt"]),
                end: JSONFields.date(meta["event_end_at"] ?? meta["eventEndAt"])
            ),
            eventCategories: eventCategories(meta),
            createdAt: JSONFields.date(row["created_at"]),
            expiresAt: JSONFields.date(row["expires_at"]),
            hubID: JSONFields.string(row["hub_id"]) ?? JSONFields.string(meta["hub_id"]),
            musicURL: JSONFields.string(meta, "original_url", "music_url", "url", "link"),
            artistName: JSONFields.string(meta, "artist_name", "artist", "track_artist"),
            venueScale: JSONFields.string(meta, "venue_scale", "venueScale"),
            rsvpEnabled: {
                let raw = meta["rsvp_enabled"] ?? meta["rsvpEnabled"]
                return !(JSONFields.bool(raw) == false || JSONFields.string(raw) == "false")
            }(),
            approvalRequired: JSONFields.bool(row["approval_required"] ?? meta["approval_required"] ?? meta["approvalRequired"]),
            capacity: JSONFields.int(row["event_capacity"] ?? meta["event_capacity"] ?? meta["eventCapacity"]),
            visibility: JSONFields.string(row["event_visibility"]) ?? JSONFields.string(meta, "event_visibility", "eventVisibility"),
            previewURL: JSONFields.string(meta, "preview_url", "previewUrl").flatMap { SoundtrackResolver.isTrustedPreview($0) ? $0 : nil },
            trackName: JSONFields.string(meta, "track_name", "track_title"),
            albumArtURL: SoundtrackResolver.artwork(JSONFields.string(meta, "album_art_url", "artworkUrl100", "artwork_url"))
        )
    }

    /// Mirrors web `displayTitleForBeacon`.
    static func displayTitle(kind: BeaconKind, meta: [String: Any]) -> String {
        if kind == .soundtrack {
            let track = JSONFields.string(meta, "track_name", "title", "track_title", "name", "track", "label")
            let artist = JSONFields.string(meta, "artist_name", "artist", "track_artist")
            if let track, let artist { return "\(track) — \(artist)" }
            if let track { return track }
        }
        if let label = JSONFields.string(meta, "label", "title", "name") { return label }
        if let text = JSONFields.string(meta, "description", "text", "message", "body") {
            return text.count > 72 ? String(text.prefix(72)) + "…" : text
        }
        return kind.label
    }

    /// Mirrors web `parseEventCategoryTags`.
    static func eventCategories(_ meta: [String: Any]) -> [String] {
        let raw = meta["event_categories"] ?? meta["eventCategories"] ?? meta["categories"]
            ?? meta["interest_tags"] ?? meta["interestTags"] ?? meta["tags"]
        if let single = JSONFields.string(raw) { return [single] }
        var seen = Set<String>()
        var result: [String] = []
        for item in raw as? [Any] ?? [] {
            let label = JSONFields.string(item)
                ?? (item as? [String: Any]).flatMap { JSONFields.string($0, "label", "name", "title") }
            guard let label, seen.insert(label.lowercased()).inserted else { continue }
            result.append(label)
        }
        return result
    }
}

/// A saved (bookmarked) event from `GET /api/me/event-bookmarks`.
public struct SavedEvent: Codable, Identifiable, Hashable, Sendable {
    public let beaconID: String
    /// `nil` when the underlying beacon no longer exists; the row is then "unavailable".
    public let title: String?
    public let schedule: EventSchedule?
    public let locationName: String?
    public let formattedAddress: String?
    public let categories: [String]
    public let latitude: Double?
    public let longitude: Double?
    public let expiresAt: Date?
    public let creatorName: String?
    public let bookmarkedAt: Date?
    public let isAvailable: Bool

    public var id: String { beaconID }

    public var placeLabel: String? { locationName ?? formattedAddress }

    public func isUpcomingOrLive(at now: Date = .now) -> Bool {
        guard isAvailable else { return false }
        if let schedule { return !schedule.isEnded(at: now) }
        if let expiresAt { return expiresAt > now }
        return true
    }

    static func decode(_ row: [String: Any]) -> SavedEvent? {
        guard let beaconID = JSONFields.string(row["beacon_id"]) else { return nil }
        // The server labels a bookmark whose beacon was deleted "Unavailable event" and returns
        // no creation timestamp for it.
        let createdAt = JSONFields.date(row["created_at"])
        let title = JSONFields.string(row["title"])
        let isAvailable = createdAt != nil
        let creator = JSONFields.bool(row["show_creator_name"]) == true ? JSONFields.string(row["creator_name"]) : nil
        return SavedEvent(
            beaconID: beaconID,
            title: isAvailable ? title : nil,
            schedule: EventSchedule(
                start: JSONFields.date(row["event_start_at"]),
                end: JSONFields.date(row["event_end_at"])
            ),
            locationName: JSONFields.string(row["location_name"]),
            formattedAddress: JSONFields.string(row["formatted_address"]),
            categories: JSONFields.stringArray(row["event_categories"]),
            latitude: JSONFields.double(row["latitude"]),
            longitude: JSONFields.double(row["longitude"]),
            expiresAt: JSONFields.date(row["expires_at"]),
            creatorName: creator,
            bookmarkedAt: JSONFields.date(row["bookmarked_at"]),
            isAvailable: isAvailable
        )
    }
}

/// An active community hub near a point, from `GET /api/hub/nearby`.
public struct NearbyHub: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double
    public let distanceMeters: Double
    public let participantCount: Int

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func decode(_ row: [String: Any]) -> NearbyHub? {
        guard
            let id = JSONFields.string(row["id"]),
            let latitude = JSONFields.double(row["geofence_lat"]),
            let longitude = JSONFields.double(row["geofence_long"])
        else { return nil }
        return NearbyHub(
            id: id,
            name: JSONFields.string(row["name"]) ?? "Community Hub",
            category: JSONFields.string(row["category"]) ?? "general",
            latitude: latitude,
            longitude: longitude,
            radiusMeters: JSONFields.double(row["radius_meters"]) ?? 50,
            distanceMeters: JSONFields.double(row["distance_meters"]) ?? 0,
            participantCount: JSONFields.int(row["participant_count"]) ?? 0
        )
    }
}

/// Map/Nearby layers, mirroring click-web `MapLayerToggles` plus the KMP community-hub layer.
/// One layer set drives both map annotations and the Nearby list.
public enum MapLayer: String, Codable, CaseIterable, Hashable, Sendable {
    case people
    case events
    case social
    case soundtracks
    case alerts
    case hubs
    case other

    public init(kind: BeaconKind) {
        switch kind {
        case .event: self = .events
        case .socialVibe: self = .social
        case .soundtrack: self = .soundtracks
        case .hazard, .utility, .sos, .study: self = .alerts
        case .other: self = .other
        }
    }

    public var label: String {
        switch self {
        case .people: "My network"
        case .events: "Events"
        case .social: "Social"
        case .soundtracks: "Soundtracks"
        case .alerts: "Alerts & utilities"
        case .hubs: "Hubs"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .people: "person.2.fill"
        case .events: "calendar"
        case .social: "sparkles"
        case .soundtracks: "music.note"
        case .alerts: "exclamationmark.triangle.fill"
        case .hubs: "building.2.fill"
        case .other: "mappin"
        }
    }
}
