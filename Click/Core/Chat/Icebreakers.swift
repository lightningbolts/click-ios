import Foundation

/// Conversation starters for a new Click (port of KMP `IcebreakerRepository`, spec §42).
/// Context prompts match the encounter context; the rest come from the general pools.
enum Icebreakers {
    private struct Prompt {
        let text: String
        var keywords: [String] = []
    }

    private static let contextPrompts: [Prompt] = [
        Prompt(text: "What's your major? How are you liking the class so far?", keywords: ["cse", "class", "lecture", "course", "101", "142", "143", "341", "351"]),
        Prompt(text: "Are you finding the assignments challenging? Want to study together sometime?", keywords: ["cse", "class", "math", "physics", "chemistry", "bio"]),
        Prompt(text: "What's your go-to study spot on campus?", keywords: ["library", "study", "odegaard", "suzzallo", "allen"]),
        Prompt(text: "What was the best thing you saw/did at the event?", keywords: ["dawg daze", "festival", "fair", "event", "concert", "show"]),
        Prompt(text: "Are you going to any other campus events this quarter?", keywords: ["dawg daze", "event", "festival"]),
        Prompt(text: "The HUB food is decent - what's your favorite spot to grab lunch on campus?", keywords: ["hub", "food", "dining", "lunch", "coffee"]),
        Prompt(text: "The Quad is beautiful! Do you come here often to hang out?", keywords: ["quad", "cherry", "blossom", "drumheller"]),
        Prompt(text: "Do you work out regularly? What's your gym routine like?", keywords: ["ima", "gym", "fitness", "workout", "rec"]),
        Prompt(text: "How long have you been involved with this club/organization?", keywords: ["club", "meeting", "organization", "asuw", "rso"]),
        Prompt(text: "How do you know the host? Are you having a good time?", keywords: ["party", "kickback", "hangout"]),
        Prompt(text: "Did you see that play?! Are you a big Huskies fan?", keywords: ["game", "husky", "football", "basketball", "stadium"])
    ]

    /// Fun, activity and getting-to-know-you pools (the KMP filler set).
    private static let generalPrompts: [String] = [
        "If you could have dinner with anyone, living or dead, who would it be?",
        "What's your most unpopular opinion?",
        "If you won the lottery tomorrow, what's the first thing you'd do?",
        "What's the last show you binge-watched?",
        "Do you have any hidden talents?",
        "What's your go-to karaoke song?",
        "What's the best trip you've ever taken?",
        "Are you a morning person or a night owl?",
        "What's your comfort food when you're stressed?",
        "If you could instantly be an expert at something, what would it be?",
        "Have you tried any good restaurants around campus lately?",
        "Want to grab coffee sometime and chat more?",
        "Are you into any sports or fitness activities?",
        "Do you play any games? Board games, video games, sports?",
        "What do you usually do on the weekends?",
        "What year are you? How are you liking UW so far?",
        "Where are you originally from?",
        "What made you choose your major?",
        "Are you living on campus or off campus?",
        "What's your favorite thing about being here so far?"
    ]

    /// KMP shows the panel while a chat has fewer than 5 messages.
    nonisolated static let messageThreshold = 5
    /// Refresh cooldown after a shuffle or a send (KMP: 15 s).
    nonisolated static let cooldown: TimeInterval = 15

    /// `count` prompts: matching context prompts first, filled from the general pools. The same
    /// `seed` gives the same prompts (stable across re-renders); nil shuffles freshly.
    nonisolated static func prompts(context: String?, count: Int = 3, seed: String? = nil) -> [String] {
        var rng = SeededGenerator(seed: seed)
        var result: [String] = []
        if let context = context?.lowercased(), !context.isEmpty {
            let matching = contextPrompts.filter { $0.keywords.contains { context.contains($0) } }.map(\.text)
            result += matching.shuffled(using: &rng).prefix(count)
        }
        result += generalPrompts.filter { !result.contains($0) }.shuffled(using: &rng).prefix(count - result.count)
        return result.shuffled(using: &rng)
    }

    /// SplitMix64: deterministic for a seed string, system-random without one.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: String?) {
            guard let seed else {
                state = UInt64.random(in: .min ... .max)
                return
            }
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
