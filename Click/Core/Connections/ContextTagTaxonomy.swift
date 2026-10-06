import Foundation

/// Encounter context tags, identical ids to KMP `ContextTagTaxonomy` so both clients read and
/// write the same `connection_encounters.context_tags` values.
public struct ContextTag: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let emoji: String
}

public enum ContextTagTaxonomy {
    public static let all: [ContextTag] = [
        ContextTag(id: "lecture", label: "Lecture / Class", emoji: "🎓"),
        ContextTag(id: "study", label: "Study Session", emoji: "📚"),
        ContextTag(id: "dorm", label: "Dorms / Residence Hall", emoji: "🛏️"),
        ContextTag(id: "party", label: "Party", emoji: "🎉"),
        ContextTag(id: "cafe", label: "Cafe / Coffee", emoji: "☕"),
        ContextTag(id: "bar", label: "Bar / Nightlife", emoji: "🍻"),
        ContextTag(id: "event", label: "Campus Event", emoji: "🏟️"),
        ContextTag(id: "sports", label: "Sports / Rec", emoji: "⚽"),
        ContextTag(id: "club", label: "Club / Org Meeting", emoji: "🤝"),
        ContextTag(id: "transit", label: "Transit / Commute", emoji: "🚌"),
        ContextTag(id: "gym", label: "Gym / Workout", emoji: "💪"),
        ContextTag(id: "conference", label: "Conference", emoji: "🎤"),
        ContextTag(id: "outdoor", label: "Outdoors / Nature", emoji: "🌲"),
        ContextTag(id: "dining", label: "Dining / Food", emoji: "🍽️"),
        ContextTag(id: "at_event", label: "At event", emoji: "📍")
    ]

    /// Server-written tag for a debounced reconnect (same place, same 12-hour block).
    public static let extendedHangout = "Extended Hangout"
    public static let maxCustomLength = 25

    public nonisolated static func isExtendedHangout(_ id: String) -> Bool {
        id.caseInsensitiveCompare(extendedHangout) == .orderedSame || id == "extended_hangout"
    }

    /// Human label for a stored tag id (custom tags are stored as their label).
    public nonisolated static func label(for id: String) -> String {
        if isExtendedHangout(id) { return "Extended hangout" }
        if id == "at_event" { return "At event" }
        if let known = all.first(where: { $0.id == id }) { return "\(known.emoji) \(known.label)" }
        // Legacy ids ("met_face_to_face") read as words; custom tags are kept as written.
        guard id.contains("_") || id == id.lowercased() else { return id }
        let words = id.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Up to four tags for an encounter, best first: each signal adds weight to the tags it
    /// points at, so a café at noon suggests Cafe before Dining, a loud room at night leans to
    /// Party, and what these people usually tag together ranks highest of all.
    public nonisolated static func suggest(_ signals: TagSignals, calendar: Calendar = .current) -> [ContextTag] {
        var scores: [String: Double] = [:]
        func add(_ weight: Double, _ ids: String...) { for id in ids { scores[id, default: 0] += weight } }

        if let type = signals.placeType?.lowercased(), let ids = placeTypes.first(where: { $0.types.contains(type) })?.ids {
            for (index, id) in ids.enumerated() { add(index == 0 ? 3 : 1.5, id) }
        }
        let place = (signals.placeName ?? "").lowercased()
        if !place.isEmpty, let ids = placeKeywords.first(where: { $0.words.contains { place.contains($0) } })?.ids {
            for (index, id) in ids.enumerated() { add(index == 0 ? 2 : 1, id) }
        }

        let hour = calendar.component(.hour, from: signals.date)
        let isWeekend = calendar.isDateInWeekend(signals.date)
        if hour >= 22 || hour <= 2 { add(1.5, "party", "bar") }
        if (6...10).contains(hour) { add(1, "cafe") }
        if (8...17).contains(hour), !isWeekend { add(1, "lecture", "study") }
        if (11...14).contains(hour) { add(1.5, "dining"); add(0.5, "cafe") }
        if (17...21).contains(hour) { add(1, "event", "club"); add(0.5, "dining") }
        if isWeekend { add(0.5, "outdoor", "party") }

        if signals.isMoving { add(2, "transit"); add(1, "outdoor", "sports") }
        if let decibels = signals.noiseDecibels {
            if decibels >= 75 { add(2, "party", "bar") } else if decibels >= 60 { add(0.5, "dining", "cafe", "event") }
            if decibels < 40 { add(1.5, "study") }
        }
        if signals.atEvent { add(4, "event") }

        // What these people tag together, weighted by how often (capped so one habit can't
        // crowd out the place itself).
        var counts: [String: Int] = [:]
        for tag in signals.pastTags { counts[tag, default: 0] += 1 }
        for (tag, count) in counts { add(Double(min(count, 3)) * 2, tag) }

        let ranked = all.enumerated()
            .filter { $0.element.id != "at_event" && scores[$0.element.id, default: 0] > 0 }
            .sorted { (scores[$0.element.id, default: 0], -$0.offset) > (scores[$1.element.id, default: 0], -$1.offset) }
            .map(\.element)
        return ranked.isEmpty ? Array(all.prefix(4)) : Array(ranked.prefix(4))
    }

    /// OpenStreetMap place types (`semantic_location.type`); the first tag is the strongest.
    private static let placeTypes: [(types: Set<String>, ids: [String])] = [
        (["university", "college", "school"], ["lecture", "study"]),
        (["library"], ["study"]),
        (["research", "research_institute", "office", "coworking", "coworking_space"], ["study", "club"]),
        (["cafe"], ["cafe", "study"]),
        (["restaurant", "fast_food", "food_court", "ice_cream"], ["dining"]),
        (["bar", "pub", "nightclub", "biergarten"], ["bar", "party"]),
        (["gym", "fitness_centre", "sports_centre", "stadium", "pitch", "swimming_pool", "track"], ["sports", "gym"]),
        (["park", "garden", "nature_reserve", "beach", "playground", "viewpoint"], ["outdoor"]),
        (["bus_stop", "station", "platform", "halt", "subway_entrance", "ferry_terminal"], ["transit"]),
        (["dormitory", "residential", "apartments", "house"], ["dorm"]),
        (["theatre", "arts_centre", "cinema", "events_venue", "conference_centre", "exhibition_centre", "community_centre"],
         ["event", "conference"])
    ]

    /// Words in a place's name; the first tag is the strongest.
    private static let placeKeywords: [(words: [String], ids: [String])] = [
        (["dorm", "residence", "residential", "housing", "apartment", "suite"], ["dorm", "study"]),
        (["library"], ["study"]),
        (["hall", "building", "classroom", "lecture", "school", "campus", "university"], ["lecture", "study"]),
        (["cafe", "café", "coffee", "espresso", "starbucks"], ["cafe", "study"]),
        (["gym", "rec", "fitness", "arena"], ["gym", "sports"]),
        (["bar", "pub", "club", "lounge"], ["bar", "party"]),
        (["bus", "train", "station", "stop", "transit"], ["transit"]),
        (["park", "trail", "beach", "garden"], ["outdoor"]),
        (["stadium", "event", "center", "theater"], ["event", "conference"]),
        (["food", "dining", "restaurant", "kitchen", "bistro"], ["dining", "cafe"])
    ]
}

/// What is known about an encounter when suggesting its tags. Everything but the date is
/// optional: suggestions start from the time alone and sharpen as the place and sensors load.
public struct TagSignals: Sendable {
    public var date: Date
    public var placeName: String?
    /// OpenStreetMap type of the place ("cafe", "university").
    public var placeType: String?
    public var isMoving = false
    public var noiseDecibels: Double?
    public var atEvent = false
    /// Tags from earlier encounters with the same people.
    public var pastTags: [String] = []

    public init(date: Date, placeName: String? = nil, placeType: String? = nil, isMoving: Bool = false,
                noiseDecibels: Double? = nil, atEvent: Bool = false, pastTags: [String] = []) {
        self.date = date
        self.placeName = placeName
        self.placeType = placeType
        self.isMoving = isMoving
        self.noiseDecibels = noiseDecibels
        self.atEvent = atEvent
        self.pastTags = pastTags
    }

    /// Motion variance (m/s²)² above which the phone was clearly being carried along.
    static let movingVariance = 1.0

    /// Signals from a loaded encounter and the earlier ones with the same people.
    public init(encounter: Encounter, history: [Encounter] = []) {
        self.init(
            date: encounter.date,
            placeName: encounter.placeName,
            placeType: encounter.placeType,
            // The server tags a tap where both phones were in motion "Active/Moving".
            isMoving: (encounter.motionVariance ?? 0) >= Self.movingVariance || encounter.contextTags.contains("Active/Moving"),
            noiseDecibels: encounter.noiseDecibels,
            atEvent: encounter.eventTitle != nil,
            pastTags: history.flatMap(\.contextTags)
        )
    }
}
