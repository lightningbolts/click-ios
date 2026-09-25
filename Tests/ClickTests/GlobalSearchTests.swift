import Testing
import Foundation
@testable import Click

@Suite("Global search")
struct GlobalSearchTests {
    private func person(_ id: String, name: String, place: String = "", tags: [String] = []) -> ConnectionItem {
        ConnectionItem(id: id, userID: "u-\(id)", connectionID: id, displayName: name, handle: "", initials: "X",
                       isOnline: false, lastActiveRelative: "", encounterLocation: place, mutualTags: tags)
    }

    @Test("Local matching covers people, interests, places, groups, and intents with scopes")
    func localMatching() {
        let group = CliqueItem(id: "g", chatID: "cg", name: "Climbing crew", memberCount: 2,
                               members: [GroupMember(userID: "u1", name: "Maya Lin", avatarURL: nil)])
        let intent = AvailabilityIntentPost(id: "i", tag: "Climbing tonight", timeframe: "tonight", expiresAt: nil)
        let results = SearchIndex.local(
            query: "climb",
            active: [person("a", name: "Theo", tags: ["Climbing"]), person("b", name: "Zoe")],
            archived: [person("c", name: "Climber Carl")],
            groups: [group],
            beacons: [], hubs: [], intents: [intent]
        )
        #expect(results.map(\.id) == ["intent.i", "person.a", "person.c", "group.g"])
        if case .person(_, let archived, let reason) = results[1] {
            #expect(!archived)
            #expect(reason == "Shared interest: Climbing")
        }
        #expect(results[2].scope == .people)
        #expect(SearchIndex.local(query: "maya", active: [], archived: [], groups: [group], beacons: [], hubs: [], intents: []).count == 1)
        #expect(SearchIndex.local(query: "  ", active: [person("a", name: "A")], archived: [], groups: [], beacons: [], hubs: [], intents: []).isEmpty)
    }

    @Test("Server message hits decode with hub routing data")
    func messageHits() {
        let hit = MessageHit.decode(["messageId": "m", "chatId": "c", "chatName": "Cafe hub", "snippet": "see you",
                                     "timestamp": 1_790_000_000_000, "isHub": true, "hubId": "h"])
        #expect(hit?.isHub == true)
        #expect(hit?.hubID == "h")
        #expect(hit?.date == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(MessageHit.decode(["snippet": "x"]) == nil)
    }
}
