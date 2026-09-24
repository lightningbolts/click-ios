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
        ContextTag(id: "dining", label: "Dining / Food", emoji: "🍽️")
    ]

    /// Server-written tag for a debounced reconnect (same place, same 12-hour block).
    public static let extendedHangout = "Extended Hangout"
    public static let maxCustomLength = 25

    /// Human label for a stored tag id (custom tags are stored as their label).
    public nonisolated static func label(for id: String) -> String {
        if id.caseInsensitiveCompare(extendedHangout) == .orderedSame || id == "extended_hangout" { return "Extended hangout" }
        if id == "at_event" { return "At event" }
        if let known = all.first(where: { $0.id == id }) { return "\(known.emoji) \(known.label)" }
        // Legacy ids ("met_face_to_face") read as words; custom tags are kept as written.
        guard id.contains("_") || id == id.lowercased() else { return id }
        let words = id.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// KMP `suggest(locationName, hourOfDay)`: location keywords first, then time of day,
    /// deduplicated, at most four.
    public nonisolated static func suggest(locationName: String?, hour: Int) -> [ContextTag] {
        var ids: [String] = []
        func add(_ values: String...) { for value in values where !ids.contains(value) { ids.append(value) } }
        let place = (locationName ?? "").lowercased()
        let keywordGroups: [([String], [String])] = [
            (["dorm", "residence", "residential", "housing", "apartment", "suite"], ["dorm", "study"]),
            (["hall", "building", "classroom", "lecture", "school", "campus"], ["lecture", "study"]),
            (["cafe", "café", "coffee", "espresso", "starbucks"], ["cafe", "study"]),
            (["gym", "rec", "fitness", "arena"], ["gym", "sports"]),
            (["bar", "pub", "club", "lounge"], ["bar", "party"]),
            (["bus", "train", "station", "stop", "transit"], ["transit"]),
            (["park", "trail", "beach", "garden"], ["outdoor"]),
            (["stadium", "event", "center", "theater"], ["event", "conference"]),
            (["food", "dining", "restaurant", "kitchen", "bistro"], ["dining", "cafe"])
        ]
        if !place.isEmpty, let match = keywordGroups.first(where: { group in group.0.contains { place.contains($0) } }) {
            match.1.forEach { add($0) }
        }
        if hour >= 22 || hour <= 2 { add("party", "bar") }
        if (8...17).contains(hour), !place.isEmpty { add("lecture", "study") }
        if (11...14).contains(hour) { add("dining", "cafe") }
        if (17...21).contains(hour) { add("event", "club", "dorm") }
        if ids.isEmpty { ids = all.prefix(4).map(\.id) }
        return ids.prefix(4).compactMap { id in all.first { $0.id == id } }
    }
}
