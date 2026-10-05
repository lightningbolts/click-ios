import Foundation

/// What two people actually have in common, for the openers a new Click is offered (spec §42).
public struct IcebreakerContext: Equatable, Sendable {
    /// Interests both profiles list (server-computed), in profile order.
    public var sharedInterests: [String] = []
    /// The event they met at, when the viewer may see it.
    public var eventTitle: String?
    /// A named place ("Cafe Allegro"), never a street address.
    public var venue: String?
    /// Context tag ids from the latest encounter ("cafe", "gym", …).
    public var tags: [String] = []
    public var metAt: Date?
    public var weather: String?
    public var encounterCount = 0

    public init(sharedInterests: [String] = [], eventTitle: String? = nil, venue: String? = nil, tags: [String] = [],
                metAt: Date? = nil, weather: String? = nil, encounterCount: Int = 0) {
        self.sharedInterests = sharedInterests
        self.eventTitle = eventTitle
        self.venue = venue
        self.tags = tags
        self.metAt = metAt
        self.weather = weather
        self.encounterCount = encounterCount
    }

    /// From the profile's shared interests and the connection's encounters.
    public init(sharedInterests: [String], encounters: [Encounter]) {
        let latest = encounters.max { $0.date < $1.date }
        self.init(
            sharedInterests: sharedInterests,
            eventTitle: encounters.lazy.sorted { $0.date > $1.date }.compactMap(\.eventTitle).first,
            venue: latest?.venue,
            tags: latest?.contextTags ?? [],
            metAt: latest?.date,
            weather: latest?.weatherCondition,
            encounterCount: encounters.count
        )
    }
}

/// Openers for a new Click, built from what the two people share: the event they met at, interests
/// in common, how and where they met. No AI: each signal has a few plain lines, the most specific
/// come first, and a simple hello is always there. They read as something a person would send:
/// short, easy to answer, never a pitch to hang out.
enum Icebreakers {
    /// KMP shows the panel while a chat has fewer than 5 messages.
    nonisolated static let messageThreshold = 5
    /// Refresh cooldown after a shuffle or a send (KMP: 15 s).
    nonisolated static let cooldown: TimeInterval = 15

    /// `count` openers for `page` (0 first; "New ideas" steps it). The same seed and page give the
    /// same openers, so they hold still across re-renders.
    nonisolated static func prompts(
        for context: IcebreakerContext,
        firstName: String? = nil,
        count: Int = 3,
        seed: String,
        page: Int = 0,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [String] {
        var rng = SeededGenerator(seed: seed)
        let specific = specificLines(context, now: now, calendar: calendar).map { $0.randomElement(using: &rng)! }
        let hello = greetings(firstName: firstName, metAt: context.metAt, now: now, calendar: calendar).randomElement(using: &rng)!
        let general = generalLines(now: now, calendar: calendar).shuffled(using: &rng)
        // The two most specific lead, then a plain hello, then the rest.
        var pool = Array(specific.prefix(2)) + [hello] + specific.dropFirst(2) + general
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0).inserted }
        guard !pool.isEmpty else { return [] }
        let start = (page * count) % pool.count
        return (0..<min(count, pool.count)).map { pool[(start + $0) % pool.count] }
    }

    /// One group of interchangeable lines per signal, most specific first.
    private nonisolated static func specificLines(_ context: IcebreakerContext, now: Date, calendar: Calendar) -> [[String]] {
        var groups: [[String]] = []
        if let event = context.eventTitle?.trimmingCharacters(in: .whitespaces), !event.isEmpty {
            groups.append(["How'd you like \(event)?", "What brought you to \(event)?", "Had you been to \(event) before?"])
        }
        var categories: Set<String> = []
        for interest in context.sharedInterests {
            guard groups.count < 4, let lines = interestLines(interest, usedCategories: &categories) else { continue }
            groups.append(lines)
        }
        if let lines = context.tags.lazy.compactMap({ tagLines[$0] }).first {
            groups.append(lines)
        }
        if let venue = context.venue?.trimmingCharacters(in: .whitespaces), !venue.isEmpty {
            groups.append(["Is \(venue) a regular spot for you?", "Do you end up at \(venue) a lot?"])
        }
        if context.encounterCount >= 2 {
            groups.append(["Feels like we keep running into each other.", "We keep crossing paths."])
        }
        if let weather = context.weather?.lowercased(), weather.contains("rain") || weather.contains("drizzle") || weather.contains("shower"),
           let metAt = context.metAt, now.timeIntervalSince(metAt) < 12 * 60 * 60 {
            groups.append(["Did you make it home before the rain picked up?"])
        }
        return groups
    }

    /// Lines for one shared interest, at most one per category so three interests in "Music"
    /// don't crowd out everything else.
    private nonisolated static func interestLines(_ interest: String, usedCategories: inout Set<String>) -> [String]? {
        let tag = interest.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return nil }
        let category = kInterestCategories.first { $0.label.caseInsensitiveCompare(tag) == .orderedSame || $0.subcategories.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }?.label
        let key = category ?? tag.lowercased()
        guard usedCategories.insert(key).inserted else { return nil }
        // Languages and acronyms ("AI/ML", "DJing") keep their capitals; the rest read as words.
        let letters = Array(tag)
        let hasAcronym = zip(letters, letters.dropFirst()).contains { $0.isUppercase && $1.isUppercase }
        let name = category == "Languages" || hasAcronym ? tag : tag.lowercased()
        let noticed = "Saw \(name) on your profile too."
        switch category {
        case "Music", "Instruments":
            return ["What have you had on repeat lately?", "\(noticed) How'd you get into it?"]
        case "Hiking":
            return ["Been on any good hikes lately?", "Any trails around here you'd recommend?"]
        case "Coffee":
            return ["Where's your go-to coffee spot around here?", "\(noticed) Any cafés you'd recommend?"]
        case "Gaming", "Puzzles & Strategy":
            return ["What are you playing right now?", "\(noticed) How long have you been into it?"]
        case "Reading":
            return ["Read anything good lately?", "\(noticed) Anything you'd recommend?"]
        case "Fitness", "Sports", "Outdoor Sports":
            return ["\(noticed) How long have you been into it?", "Any good spots around here for \(name)?"]
        case "Tech":
            return ["Working on anything fun right now?", "\(noticed) What got you into it?"]
        case "Art", "Photography":
            return ["Working on anything right now?", "\(noticed) How'd you get into it?"]
        case "Film":
            return ["Seen anything good lately?", "\(noticed) Anything you'd recommend?"]
        case "Food":
            return ["Any food spots around here you'd recommend?", "What's the best thing you've made lately?"]
        case "Travel":
            return ["Where's the best place you've been recently?", "Any trips coming up?"]
        case "Languages":
            return ["\(noticed) Learning it, or already fluent?"]
        case "Animals":
            return ["\(noticed) Do you have any pets?"]
        default:
            return ["\(noticed) How'd you get into it?"]
        }
    }

    /// How they met, by context tag. Questions about the moment itself, easy to answer.
    private nonisolated static let tagLines: [String: [String]] = [
        "lecture": ["How are you finding the class so far?", "Is that class one you picked, or a requirement?"],
        "study": ["Did you get through everything you were studying for?", "How's the studying going?"],
        "dorm": ["How are you liking the dorm so far?"],
        "party": ["How was the rest of the night?", "How do you know the host?"],
        "cafe": ["Is that your usual coffee spot?", "What do you usually get there?"],
        "bar": ["How was the rest of the night?"],
        "event": ["Did you stay for the rest of it?", "How'd you like the rest of the event?"],
        "conference": ["Any talks worth catching?", "What's been the best part of the conference so far?"],
        "sports": ["Do you play there often?"],
        "club": ["How long have you been part of the club?"],
        "transit": ["Do you take that route most days?"],
        "gym": ["Is that your usual gym time?", "What are you training for these days?"],
        "outdoor": ["Do you get out there often?"],
        "dining": ["Anything there you'd recommend?"]
    ]

    private nonisolated static func greetings(firstName: String?, metAt: Date?, now: Date, calendar: Calendar) -> [String] {
        let hey = firstName.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : "Hey \($0)!" } ?? "Hey!"
        if let metAt, calendar.isDate(metAt, inSameDayAs: now) {
            return ["\(hey) Good meeting you today.", "\(hey) Nice meeting you earlier."]
        }
        return ["\(hey) Good to meet you.", "\(hey) Nice meeting you."]
    }

    /// Low-key questions for when there's little to go on.
    private nonisolated static func generalLines(now: Date, calendar: Calendar) -> [String] {
        var lines = [
            "How's your week going?",
            "What's keeping you busy these days?",
            "What's something you're looking forward to?",
            "Found any good spots around here lately?",
            "What do you usually get up to outside of work or class?"
        ]
        // Thursday through Sunday, the weekend is the natural thing to ask about.
        let weekday = calendar.component(.weekday, from: now)
        if [5, 6, 7, 1].contains(weekday) { lines.append("Anything fun planned for the weekend?") }
        return lines
    }

    /// SplitMix64: deterministic for a seed string.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: String) {
            state = seed.utf8.reduce(1_982_739_817) { $0 &* 31 &+ UInt64($1) }
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
