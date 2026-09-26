import CoreLocation
import Foundation

/// A named step in a friendship, earned by hangouts together (both people see the same level).
public struct FriendshipLevel: Equatable, Sendable {
    public let rank: Int
    public let name: String
    public let symbol: String
    /// Hangouts needed to reach it.
    public let threshold: Int

    public static let all: [FriendshipLevel] = [
        FriendshipLevel(rank: 1, name: "New Click", symbol: "sparkles", threshold: 1),
        FriendshipLevel(rank: 2, name: "Familiar", symbol: "hand.wave.fill", threshold: 3),
        FriendshipLevel(rank: 3, name: "Regulars", symbol: "cup.and.saucer.fill", threshold: 6),
        FriendshipLevel(rank: 4, name: "Close", symbol: "heart.fill", threshold: 12),
        FriendshipLevel(rank: 5, name: "Inseparable", symbol: "infinity", threshold: 25)
    ]

    public static func forHangouts(_ count: Int) -> FriendshipLevel {
        all.last { count >= $0.threshold } ?? all[0]
    }
}

/// A place you've met at least once (several encounters at one venue are one spot).
public struct FriendshipSpot: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let coordinate: CLLocationCoordinate2D?
    public let firstVisit: Date
    public var visits: Int

    public static func == (a: FriendshipSpot, b: FriendshipSpot) -> Bool {
        a.id == b.id && a.visits == b.visits && a.firstVisit == b.firstVisit
    }
}

/// Everything the profile, the souvenir and "Your story" say about a friendship, derived only
/// from real encounters (nothing is shown that the timeline can't back up).
public struct FriendshipStats: Equatable, Sendable {
    public enum TimeOfDay: String, Sendable { case morning, afternoon, evening, night }

    public let hangouts: Int
    public let firstMet: Encounter?
    public let lastMet: Encounter?
    /// Distinct spots, in the order you first met there.
    public let spots: [FriendshipSpot]
    public let neighborhoods: Int
    public let level: FriendshipLevel
    public let nextLevel: FriendshipLevel?
    /// Hangouts still needed for `nextLevel`.
    public let toNextLevel: Int
    /// Consecutive weeks with a hangout, counting this week (or last week, while this one is
    /// still open). Zero when the run has ended.
    public let weekStreak: Int
    public let longestWeekStreak: Int
    public let favoriteTime: TimeOfDay?
    public let coldest: Encounter?
    public let warmest: Encounter?

    public var topSpot: FriendshipSpot? { spots.max { $0.visits < $1.visits }.flatMap { $0.visits > 1 ? $0 : nil } }
    public var isEmpty: Bool { hangouts == 0 }

    /// Progress from the current level to the next (0…1; 1 at the top level).
    public var levelProgress: Double {
        guard let nextLevel else { return 1 }
        let span = Double(nextLevel.threshold - level.threshold)
        return min(1, max(0, Double(hangouts - level.threshold) / span))
    }

    static func spotKey(_ encounter: Encounter) -> String? {
        if let name = encounter.placeName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty {
            return "name:\(name)"
        }
        guard let lat = encounter.latitude, let lon = encounter.longitude else { return nil }
        // ~110 m cells: the same café on two days is one spot.
        return String(format: "geo:%.3f,%.3f", lat, lon)
    }

    public static func compute(_ encounters: [Encounter], now: Date = .now, calendar: Calendar = .current) -> FriendshipStats {
        let ordered = encounters.sorted { $0.date < $1.date }
        var spots: [FriendshipSpot] = []
        var spotIndex: [String: Int] = [:]
        for encounter in ordered {
            guard let key = spotKey(encounter) else { continue }
            if let index = spotIndex[key] {
                spots[index].visits += 1
            } else {
                spotIndex[key] = spots.count
                let coordinate = encounter.latitude.flatMap { lat in encounter.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } }
                spots.append(FriendshipSpot(id: key, name: encounter.placeName, coordinate: coordinate, firstVisit: encounter.date, visits: 1))
            }
        }
        let neighborhoods = Set(ordered.compactMap { ($0.neighbourhood ?? $0.city)?.lowercased() }).count

        let level = FriendshipLevel.forHangouts(ordered.count)
        let next = FriendshipLevel.all.first { $0.rank == level.rank + 1 }

        // Week streaks.
        let weeks = Set(ordered.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0.date)?.start })
        func previousWeek(_ start: Date) -> Date? { calendar.date(byAdding: .weekOfYear, value: -1, to: start) }
        var current = 0
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            var cursor: Date? = weeks.contains(thisWeek) ? thisWeek : previousWeek(thisWeek)
            while let week = cursor, weeks.contains(week) {
                current += 1
                cursor = previousWeek(week)
            }
        }
        var longest = 0
        for week in weeks where !(previousWeek(week).map(weeks.contains) ?? false) {
            var length = 0
            var cursor: Date? = week
            while let w = cursor, weeks.contains(w) {
                length += 1
                cursor = calendar.date(byAdding: .weekOfYear, value: 1, to: w)
            }
            longest = max(longest, length)
        }

        // When you usually meet (needs a clear pattern: at least 3 hangouts).
        var times: [TimeOfDay: Int] = [:]
        for encounter in ordered {
            let hour = calendar.component(.hour, from: encounter.date)
            let slot: TimeOfDay = switch hour {
            case 5..<12: .morning
            case 12..<17: .afternoon
            case 17..<22: .evening
            default: .night
            }
            times[slot, default: 0] += 1
        }
        let favorite = ordered.count >= 3 ? times.max { $0.value < $1.value }.map(\.key) : nil
        let withTemperature = ordered.filter { $0.temperatureCelsius != nil }

        return FriendshipStats(
            hangouts: ordered.count,
            firstMet: ordered.first,
            lastMet: ordered.last,
            spots: spots,
            neighborhoods: neighborhoods,
            level: level,
            nextLevel: next,
            toNextLevel: next.map { max(0, $0.threshold - ordered.count) } ?? 0,
            weekStreak: current,
            longestWeekStreak: longest,
            favoriteTime: favorite,
            coldest: withTemperature.count >= 2 ? withTemperature.min { $0.temperatureCelsius! < $1.temperatureCelsius! } : nil,
            warmest: withTemperature.count >= 2 ? withTemperature.max { $0.temperatureCelsius! < $1.temperatureCelsius! } : nil
        )
    }
}

/// What the newest hangout added (for the post-tap souvenir).
public struct HangoutHighlights: Equatable, Sendable {
    /// 1-based count of this hangout.
    public let ordinal: Int
    public let isNewSpot: Bool
    /// Set when this hangout reached a new level.
    public let leveledUpTo: FriendshipLevel?
    /// A round-number hangout (5th, 10th, 25th…).
    public let isMilestone: Bool
    public let weekStreak: Int

    public static let milestones: Set<Int> = [5, 10, 25, 50, 75, 100, 150, 200, 250, 365, 500]

    public static func of(_ encounters: [Encounter], now: Date = .now, calendar: Calendar = .current) -> HangoutHighlights? {
        let ordered = encounters.sorted { $0.date < $1.date }
        guard let latest = ordered.last else { return nil }
        let earlier = ordered.dropLast()
        let earlierSpots = Set(earlier.compactMap(FriendshipStats.spotKey))
        let before = FriendshipLevel.forHangouts(earlier.count)
        let after = FriendshipLevel.forHangouts(ordered.count)
        return HangoutHighlights(
            ordinal: ordered.count,
            isNewSpot: ordered.count > 1 && FriendshipStats.spotKey(latest).map { !earlierSpots.contains($0) } == true,
            leveledUpTo: ordered.count > 1 && after.rank > before.rank ? after : nil,
            isMilestone: milestones.contains(ordered.count),
            weekStreak: FriendshipStats.compute(ordered, now: now, calendar: calendar).weekStreak
        )
    }
}
