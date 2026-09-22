import Foundation

/// Exactly five personality traits required during onboarding.
public let kPersonalityRequiredTagCount: Int = 5

/// A display group for personality traits.
public struct PersonalityTraitGroup: Identifiable, Hashable, Sendable {
    public var id: String { title }
    public let title: String
    public let traits: [String]

    public init(title: String, traits: [String]) {
        self.title = title
        self.traits = traits
    }
}

/// Curated social traits grouped by affinity.
public let kPersonalityTraitGroups: [PersonalityTraitGroup] = [
    PersonalityTraitGroup(
        title: "Social",
        traits: ["Outgoing", "Warm", "Empathetic", "Supportive", "Loyal", "Humorous", "Witty"]
    ),
    PersonalityTraitGroup(
        title: "Energy",
        traits: ["Adventurous", "Spontaneous", "Playful", "Bold", "Passionate", "Ambitious"]
    ),
    PersonalityTraitGroup(
        title: "Mind",
        traits: ["Curious", "Thoughtful", "Analytical", "Observant", "Creative"]
    ),
    PersonalityTraitGroup(
        title: "Style",
        traits: ["Grounded", "Chill", "Easygoing", "Independent", "Authentic", "Optimistic"]
    ),
]

/// All 24 canonical traits.
public let kPersonalityTraits: [String] = kPersonalityTraitGroups.flatMap { $0.traits }

/// Canonicalizes an input list of tags against the canonical taxonomy.
public func canonicalizePersonalityTags(_ tags: [String]) -> [String] {
    let lowerMap = Dictionary(uniqueKeysWithValues: kPersonalityTraits.map { ($0.lowercased(), $0) })
    var seen = Set<String>()
    var result: [String] = []

    for tag in tags {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let canonical = lowerMap[clean], !seen.contains(canonical) {
            seen.insert(canonical)
            result.append(canonical)
        }
    }
    return result
}
