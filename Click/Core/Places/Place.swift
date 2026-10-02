import CoreLocation
import Foundation

// Click Places value types (click-web CLICK_PLACES_SPEC.md §5.1). Decoded leniently from the BFF's
// snake_case JSON with `JSONFields`; unknown enum strings fall back instead of failing.

public enum PlaceCategory: String, Codable, CaseIterable, Sendable {
    case cafe, bar, nightlife, musicVenue = "music_venue", restaurant, gym, coworking,
         studySpace = "study_space", entertainment, bookstore, campusSpace = "campus_space", other

    public init(raw: String?) {
        self = raw.flatMap(PlaceCategory.init(rawValue:)) ?? .other
    }

    /// §1.3 labels.
    public var label: String {
        switch self {
        case .cafe: "Café"
        case .bar: "Bar"
        case .nightlife: "Nightlife"
        case .musicVenue: "Music venue"
        case .restaurant: "Restaurant"
        case .gym: "Gym"
        case .coworking: "Coworking"
        case .studySpace: "Study space"
        case .entertainment: "Entertainment"
        case .bookstore: "Bookstore"
        case .campusSpace: "Campus space"
        case .other: "Place"
        }
    }

    /// §1.3 SF Symbols.
    public var symbol: String {
        switch self {
        case .cafe: "cup.and.saucer.fill"
        case .bar: "wineglass.fill"
        case .nightlife: "sparkles"
        case .musicVenue: "music.mic"
        case .restaurant: "fork.knife"
        case .gym: "figure.strengthtraining.traditional"
        case .coworking: "laptopcomputer"
        case .studySpace: "books.vertical.fill"
        case .entertainment: "gamecontroller.fill"
        case .bookstore: "book.fill"
        case .campusSpace: "building.columns.fill"
        case .other: "mappin.circle.fill"
        }
    }
}

public enum EnergyLabel: String, Codable, CaseIterable, Sendable {
    case chill, steady, lively, packed

    public var title: String { rawValue.capitalized }

    /// 1 Chill … 4 Packed.
    public var value: Int {
        switch self {
        case .chill: 1
        case .steady: 2
        case .lively: 3
        case .packed: 4
        }
    }

    public init?(value: Int) {
        guard let label = Self.allCases.first(where: { $0.value == value }) else { return nil }
        self = label
    }
}

public struct PulseSummary: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case live, stale, none }
    public enum Confidence: String, Codable, Sendable { case low, medium, high }

    public let state: State
    public let label: EnergyLabel?
    public let energyScore: Double?
    public let reportCount: Int
    public let newestAt: Date?
    public let confidence: Confidence?
    /// Raw counts, Chill … Packed.
    public let distribution: [Int]
    public let talkableYes: Int
    public let talkableNo: Int
    public let categoryQuestion: String?
    /// Raw counts for answers 1…3.
    public let categoryCounts: [Int]?
    public let windowMinutes: Int

    public static let empty = PulseSummary(
        state: .none, label: nil, energyScore: nil, reportCount: 0, newestAt: nil, confidence: nil,
        distribution: [0, 0, 0, 0], talkableYes: 0, talkableNo: 0, categoryQuestion: nil, categoryCounts: nil, windowMinutes: 90
    )

    public static func decode(_ row: [String: Any]?) -> PulseSummary {
        guard let row else { return .empty }
        let talkable = JSONFields.dictionary(row["talkable"]) ?? [:]
        let category = JSONFields.dictionary(row["category"])
        let distribution = (row["distribution"] as? [Any] ?? []).map { JSONFields.int($0) ?? 0 }
        return PulseSummary(
            state: JSONFields.string(row["state"]).flatMap(State.init(rawValue:)) ?? .none,
            label: JSONFields.string(row["label"]).flatMap(EnergyLabel.init(rawValue:)),
            energyScore: JSONFields.double(row["energy_score"]),
            reportCount: JSONFields.int(row["report_count"]) ?? 0,
            newestAt: JSONFields.date(row["newest_at"]),
            confidence: JSONFields.string(row["confidence"]).flatMap(Confidence.init(rawValue:)),
            distribution: distribution.count == 4 ? distribution : [0, 0, 0, 0],
            talkableYes: JSONFields.int(talkable["yes"]) ?? 0,
            talkableNo: JSONFields.int(talkable["no"]) ?? 0,
            categoryQuestion: category.flatMap { JSONFields.string($0["question"]) },
            categoryCounts: category.map { ($0["counts"] as? [Any] ?? []).map { JSONFields.int($0) ?? 0 } },
            windowMinutes: JSONFields.int(row["window_minutes"]) ?? 90
        )
    }
}

public struct PlaceEventRef: Codable, Equatable, Identifiable, Sendable {
    public let beaconID: String
    public let title: String
    public let startsAt: Date?
    public let endsAt: Date?
    public let isLive: Bool
    public var id: String { beaconID }

    public static func decode(_ row: [String: Any]?) -> PlaceEventRef? {
        guard let row, let id = JSONFields.string(row["beacon_id"]) else { return nil }
        return PlaceEventRef(
            beaconID: id,
            title: JSONFields.string(row["title"]) ?? "Event",
            startsAt: JSONFields.date(row["starts_at"]),
            endsAt: JSONFields.date(row["ends_at"]),
            isLive: JSONFields.bool(row["is_live"]) ?? false
        )
    }
}

public struct PlaceViewerFlags: Codable, Equatable, Sendable {
    public let checkedIn: Bool
    public let hasHistory: Bool
    public let connectionsBeenHereCount: Int

    public static func decode(_ row: [String: Any]?) -> PlaceViewerFlags? {
        guard let row else { return nil }
        return PlaceViewerFlags(
            checkedIn: JSONFields.bool(row["checked_in"]) ?? false,
            hasHistory: JSONFields.bool(row["has_history"]) ?? false,
            connectionsBeenHereCount: JSONFields.int(row["connections_been_here_count"]) ?? 0
        )
    }
}

public struct PlaceSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let slug: String
    public let name: String
    public let category: PlaceCategory
    public let photoURL: URL?
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Int
    public let distanceMeters: Double?
    public let addressLine: String?
    public let city: String?
    public let openNow: Bool?
    public let pulse: PulseSummary
    public let hereNowCount: Int
    public let eventsTodayCount: Int
    public let nextEvent: PlaceEventRef?
    public let hubID: String?
    public let viewer: PlaceViewerFlags?

    public var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    public static func decode(_ row: [String: Any]?) -> PlaceSummary? {
        guard let row,
              let id = JSONFields.string(row["id"]),
              let latitude = JSONFields.double(row["latitude"]),
              let longitude = JSONFields.double(row["longitude"]) else { return nil }
        return PlaceSummary(
            id: id,
            slug: JSONFields.string(row["slug"]) ?? id,
            name: JSONFields.string(row["name"]) ?? "Place",
            category: PlaceCategory(raw: JSONFields.string(row["category"])),
            photoURL: JSONFields.string(row["photo_url"]).flatMap(URL.init(string:)),
            latitude: latitude,
            longitude: longitude,
            radiusMeters: JSONFields.int(row["radius_meters"]) ?? 75,
            distanceMeters: JSONFields.double(row["distance_meters"]),
            addressLine: JSONFields.string(row["address_line"]),
            city: JSONFields.string(row["city"]),
            openNow: JSONFields.bool(row["open_now"]),
            pulse: PulseSummary.decode(JSONFields.dictionary(row["pulse"])),
            hereNowCount: JSONFields.int(row["here_now_count"]) ?? 0,
            eventsTodayCount: JSONFields.int(row["events_today_count"]) ?? 0,
            nextEvent: PlaceEventRef.decode(JSONFields.dictionary(row["next_event"])),
            hubID: JSONFields.string(row["hub_id"]),
            viewer: PlaceViewerFlags.decode(JSONFields.dictionary(row["viewer"]))
        )
    }
}

public struct PulseQuestion: Codable, Equatable, Identifiable, Sendable {
    public struct Option: Codable, Equatable, Hashable, Sendable {
        public let value: Int
        public let label: String
    }

    /// "energy" | "talkable" | "category" | "would_return"
    public let key: String
    public let categoryQuestion: String?
    public let prompt: String
    public let required: Bool
    /// "present" | "leaving"
    public let phase: String
    public let options: [Option]
    public var id: String { key }

    public static func decode(_ row: [String: Any]) -> PulseQuestion? {
        guard let key = JSONFields.string(row["key"]), let prompt = JSONFields.string(row["prompt"]) else { return nil }
        let options = JSONFields.rows(row["options"]).compactMap { option -> Option? in
            guard let value = JSONFields.int(option["value"]), let label = JSONFields.string(option["label"]) else { return nil }
            return Option(value: value, label: label)
        }
        return PulseQuestion(
            key: key,
            categoryQuestion: JSONFields.string(row["category_question"]),
            prompt: prompt,
            required: JSONFields.bool(row["required"]) ?? false,
            phase: JSONFields.string(row["phase"]) ?? "present",
            options: options
        )
    }
}

public struct PlacePerson: Equatable, Identifiable, Sendable {
    public let userID: String
    public let name: String
    public let avatarURL: URL?
    /// Only for "You met here" (the viewer's own history).
    public let lastMetAt: Date?
    public var id: String { userID }

    static func decode(_ row: [String: Any]) -> PlacePerson? {
        guard let id = JSONFields.string(row["user_id"]) else { return nil }
        return PlacePerson(
            userID: id,
            name: JSONFields.string(row["name"]) ?? "Someone",
            avatarURL: JSONFields.string(row["avatar_url"]).flatMap(URL.init(string:)),
            lastMetAt: JSONFields.date(row["last_met_at"])
        )
    }
}

public struct PlacePattern: Equatable, Sendable {
    public let label: EnergyLabel
    public let reportCount: Int
    public let weeks: Int
}

public struct ClicksBeenHere: Equatable, Sendable {
    public let count: Int
    public let names: [String]
}

public struct YouMetHere: Equatable, Sendable {
    public let total: Int
    public let people: [PlacePerson]
}

public struct PlaceOwnHistory: Equatable, Sendable {
    public let checkInCount: Int
    public let lastCheckInAt: Date?
    public let encounterCount: Int
}

public struct PlaceCheckInState: Equatable, Sendable {
    public let active: Bool
    public let checkInID: String
    public let checkedInAt: Date?
    public let expiresAt: Date?
    /// "gps" | "qr"
    public let proof: String
    public let shareWithConnections: Bool
    /// Present on check-in responses (§5.4).
    public var hubID: String? = nil
    public var hereNowCount: Int? = nil

    static func decode(_ row: [String: Any]?) -> PlaceCheckInState? {
        guard let row else { return nil }
        let active = JSONFields.bool(row["active"]) ?? JSONFields.bool(row["checked_in"]) ?? false
        guard active, let id = JSONFields.string(row["check_in_id"]) else { return nil }
        return PlaceCheckInState(
            active: true,
            checkInID: id,
            checkedInAt: JSONFields.date(row["checked_in_at"]),
            expiresAt: JSONFields.date(row["expires_at"]),
            proof: JSONFields.string(row["proof"]) ?? "gps",
            shareWithConnections: JSONFields.bool(row["share_with_connections"]) ?? false,
            hubID: JSONFields.string(row["hub_id"]),
            hereNowCount: JSONFields.int(row["here_now_count"])
        )
    }
}

public struct PulseEligibility: Equatable, Sendable {
    public enum Reason: String, Sendable { case notPresent = "not_present", cooldown, manager }

    public struct LastPulse: Equatable, Sendable {
        public let id: String
        public let energy: Int?
        public let createdAt: Date?
        public let editableUntil: Date?
    }

    public let canPulse: Bool
    public let reason: Reason?
    public let cooldownUntil: Date?
    public let questions: [PulseQuestion]
    public let leavingQuestions: [PulseQuestion]
    public let myLastPulse: LastPulse?

    static func decode(_ row: [String: Any]?) -> PulseEligibility? {
        guard let row else { return nil }
        let last = JSONFields.dictionary(row["my_last_pulse"]).flatMap { last -> LastPulse? in
            guard let id = JSONFields.string(last["id"]) else { return nil }
            return LastPulse(id: id, energy: JSONFields.int(last["energy"]), createdAt: JSONFields.date(last["created_at"]), editableUntil: JSONFields.date(last["editable_until"]))
        }
        return PulseEligibility(
            canPulse: JSONFields.bool(row["can_pulse"]) ?? false,
            reason: JSONFields.string(row["reason"]).flatMap(Reason.init(rawValue:)),
            cooldownUntil: JSONFields.date(row["cooldown_until"]),
            questions: JSONFields.rows(row["questions"]).compactMap(PulseQuestion.decode),
            leavingQuestions: JSONFields.rows(row["leaving_questions"]).compactMap(PulseQuestion.decode),
            myLastPulse: last
        )
    }
}

public struct PlaceHubRef: Equatable, Sendable {
    public let id: String
    public let name: String
    public let joined: Bool
}

public struct PlaceDetail: Equatable, Sendable {
    public var summary: PlaceSummary
    public let description: String?
    public let websiteURL: URL?
    public let todayHoursLabel: String?
    public let appleMapsURL: URL?
    public let googleMapsURL: URL?
    public let pattern: PlacePattern?
    public let upcomingEvents: [PlaceEventRef]
    public let hereNowConnections: [PlacePerson]
    public let clicksBeenHere: ClicksBeenHere?
    public let youMetHere: YouMetHere?
    public let ownHistory: PlaceOwnHistory?
    public var checkIn: PlaceCheckInState?
    public let pulseEligibility: PulseEligibility?
    public let hub: PlaceHubRef?
    public let isManager: Bool

    public var id: String { summary.id }

    public static func decode(_ row: [String: Any]?) -> PlaceDetail? {
        guard let row, let summary = PlaceSummary.decode(row) else { return nil }
        let directions = JSONFields.dictionary(row["directions"]) ?? [:]
        let pattern = JSONFields.dictionary(row["pattern"]).flatMap { p -> PlacePattern? in
            guard let label = JSONFields.string(p["label"]).flatMap(EnergyLabel.init(rawValue:)) else { return nil }
            return PlacePattern(label: label, reportCount: JSONFields.int(p["report_count"]) ?? 0, weeks: JSONFields.int(p["weeks"]) ?? 0)
        }
        let been = JSONFields.dictionary(row["clicks_been_here"]).map {
            ClicksBeenHere(count: JSONFields.int($0["count"]) ?? 0, names: JSONFields.stringArray($0["names"]))
        }
        let met = JSONFields.dictionary(row["you_met_here"]).map {
            YouMetHere(total: JSONFields.int($0["total"]) ?? 0, people: JSONFields.rows($0["people"]).compactMap(PlacePerson.decode))
        }
        let history = JSONFields.dictionary(row["own_history"]).map {
            PlaceOwnHistory(
                checkInCount: JSONFields.int($0["check_in_count"]) ?? 0,
                lastCheckInAt: JSONFields.date($0["last_check_in_at"]),
                encounterCount: JSONFields.int($0["encounter_count"]) ?? 0
            )
        }
        let hub = JSONFields.dictionary(row["hub"]).flatMap { h -> PlaceHubRef? in
            guard let id = JSONFields.string(h["id"]) else { return nil }
            return PlaceHubRef(id: id, name: JSONFields.string(h["name"]) ?? summary.name, joined: JSONFields.bool(h["joined"]) ?? false)
        }
        return PlaceDetail(
            summary: summary,
            description: JSONFields.string(row["description"]),
            websiteURL: JSONFields.string(row["website_url"]).flatMap(URL.init(string:)),
            todayHoursLabel: JSONFields.string(row["today_hours_label"]),
            appleMapsURL: JSONFields.string(directions["apple_maps_url"]).flatMap(URL.init(string:)),
            googleMapsURL: JSONFields.string(directions["google_maps_url"]).flatMap(URL.init(string:)),
            pattern: pattern,
            upcomingEvents: JSONFields.rows(row["upcoming_events"]).compactMap(PlaceEventRef.decode),
            hereNowConnections: JSONFields.rows(row["here_now_connections"]).compactMap(PlacePerson.decode),
            clicksBeenHere: been,
            youMetHere: met,
            ownHistory: history,
            checkIn: PlaceCheckInState.decode(JSONFields.dictionary(row["check_in"])),
            pulseEligibility: PulseEligibility.decode(JSONFields.dictionary(row["pulse_eligibility"])),
            hub: hub,
            isManager: JSONFields.bool(row["is_manager"]) ?? false
        )
    }
}

/// One row of `GET /api/me/places`.
public struct MyPlaceVisit: Equatable, Identifiable, Sendable {
    public let place: PlaceSummary
    public let checkInCount: Int
    public let lastCheckInAt: Date?
    public let encounterCount: Int
    public var id: String { place.id }

    static func decode(_ row: [String: Any]) -> MyPlaceVisit? {
        guard let place = PlaceSummary.decode(JSONFields.dictionary(row["place"])) else { return nil }
        return MyPlaceVisit(
            place: place,
            checkInCount: JSONFields.int(row["check_in_count"]) ?? 0,
            lastCheckInAt: JSONFields.date(row["last_check_in_at"]),
            encounterCount: JSONFields.int(row["encounter_count"]) ?? 0
        )
    }
}
