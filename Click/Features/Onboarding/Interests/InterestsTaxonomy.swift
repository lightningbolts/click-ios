import Foundation

/// Minimum tags required during mobile onboarding.
public let kInterestOnboardingMinTags: Int = 5

/// A top-level interest category containing curated subcategories.
public struct InterestCategory: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public let emoji: String
    public let label: String
    public let subcategories: [String]

    public init(emoji: String, label: String, subcategories: [String]) {
        self.emoji = emoji
        self.label = label
        self.subcategories = subcategories
    }
}

/// Canonical 21 interest categories and subcategories for Click.
public let kInterestCategories: [InterestCategory] = [
    InterestCategory(
        emoji: "🎵",
        label: "Music",
        subcategories: ["Live Shows", "DJing", "Producing", "Guitar", "Piano", "Singing", "Alto Sax", "Tenor Sax", "Drums", "Violin", "Bass", "Songwriting"]
    ),
    InterestCategory(
        emoji: "🎼",
        label: "Instruments",
        subcategories: ["Alto Sax", "Tenor Sax", "Trumpet", "Clarinet", "Cello", "Flute", "Ukulele", "Synth", "Beat Making"]
    ),
    InterestCategory(
        emoji: "🥾",
        label: "Hiking",
        subcategories: ["Day Hikes", "Backpacking", "Trail Running", "Rock Climbing", "Scrambling", "Nature Walks"]
    ),
    InterestCategory(
        emoji: "☕",
        label: "Coffee",
        subcategories: ["Espresso", "Pour Over", "Cafe Hopping", "Latte Art", "Home Brewing"]
    ),
    InterestCategory(
        emoji: "🎮",
        label: "Gaming",
        subcategories: ["PC", "Console", "Indie", "Board Games", "VR", "Competitive", "Co-op", "RPG", "Strategy"]
    ),
    InterestCategory(
        emoji: "📚",
        label: "Reading",
        subcategories: ["Fiction", "Non-Fiction", "Sci-Fi", "Fantasy", "Book Clubs", "Poetry"]
    ),
    InterestCategory(
        emoji: "💪",
        label: "Fitness",
        subcategories: ["Gym", "Yoga", "CrossFit", "Running", "Swimming", "Martial Arts", "Pilates", "Cycling"]
    ),
    InterestCategory(
        emoji: "💻",
        label: "Tech",
        subcategories: ["AI/ML", "Web Dev", "Mobile Dev", "Cybersecurity", "Hardware", "Open Source", "Cloud", "Data Science"]
    ),
    InterestCategory(
        emoji: "🎨",
        label: "Art",
        subcategories: ["Painting", "Sketching", "Digital Art", "Sculpture", "Ceramics", "Street Art", "Calligraphy", "Graphic Design"]
    ),
    InterestCategory(
        emoji: "🎬",
        label: "Film",
        subcategories: ["Indie Film", "Horror", "Documentaries", "Animation", "Film Making"]
    ),
    InterestCategory(
        emoji: "🍕",
        label: "Food",
        subcategories: ["Cooking", "Baking", "Food Trucks", "Fine Dining", "Vegan", "Meal Prep"]
    ),
    InterestCategory(
        emoji: "✈️",
        label: "Travel",
        subcategories: ["Backpacking", "Road Trips", "City Breaks", "Solo Travel", "Camping", "Digital Nomad", "Hostels"]
    ),
    InterestCategory(
        emoji: "⚽",
        label: "Sports",
        subcategories: ["Basketball", "Soccer", "Baseball", "Football", "Softball", "Ultimate", "Tennis", "Volleyball", "Skiing", "Surfing"]
    ),
    InterestCategory(
        emoji: "🏃",
        label: "Outdoor Sports",
        subcategories: ["Running", "Cycling", "Triathlon", "Climbing", "Skiing", "Snowboarding", "Surfing"]
    ),
    InterestCategory(
        emoji: "🤝",
        label: "Volunteering",
        subcategories: ["Environment", "Education", "Community", "Animal Welfare", "Mentoring"]
    ),
    InterestCategory(
        emoji: "📸",
        label: "Photography",
        subcategories: ["Street", "Portrait", "Landscape", "Film Photography", "Drone", "Concert Photography", "Editing"]
    ),
    InterestCategory(
        emoji: "🧘",
        label: "Wellness",
        subcategories: ["Meditation", "Mindfulness", "Breathwork", "Journaling", "Mental Health"]
    ),
    InterestCategory(
        emoji: "🗣️",
        label: "Languages",
        subcategories: ["Spanish", "French", "Mandarin", "Japanese", "Korean", "Language Exchange"]
    ),
    InterestCategory(
        emoji: "🎭",
        label: "Performing Arts",
        subcategories: ["Theater", "Improv", "Acting", "Stand-up Comedy", "Dance"]
    ),
    InterestCategory(
        emoji: "🐶",
        label: "Animals",
        subcategories: ["Dogs", "Cats", "Birds", "Animal Rescue", "Pet Training"]
    ),
    InterestCategory(
        emoji: "🧩",
        label: "Puzzles & Strategy",
        subcategories: ["Chess", "Sudoku", "Escape Rooms", "Crosswords", "Go"]
    ),
]

/// Returns all predefined interest tags (categories + subcategories) in lowercase.
public func predefinedInterestTags() -> Set<String> {
    Set(kInterestCategories.flatMap { category in
        [category.label] + category.subcategories
    }.map { $0.lowercased() })
}

/// Filters an array of tags to keep only known taxonomy tags.
public func filterToPredefinedInterestTags(_ tags: [String]) -> [String] {
    let predefined = predefinedInterestTags()
    return tags.filter { predefined.contains($0.lowercased()) }
}
