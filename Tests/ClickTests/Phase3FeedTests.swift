import Testing
import Foundation
@testable import Click

@Suite("Phase 3 Feeds, Clicks, and Profile Tests")
struct Phase3FeedTests {
    @Test("Time-based salutation handles different hours correctly")
    func testSalutations() {
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 22

        // Morning: 9am
        comps.hour = 9
        let morningDate = calendar.date(from: comps)!
        #expect(HomeFeedSnapshot.timeBasedSalutation(for: "Alex", date: morningDate) == "Good morning, Alex.")

        // Afternoon: 2pm (14:00)
        comps.hour = 14
        let afternoonDate = calendar.date(from: comps)!
        #expect(HomeFeedSnapshot.timeBasedSalutation(for: "Alex", date: afternoonDate) == "Good afternoon, Alex.")

        // Evening: 8pm (20:00)
        comps.hour = 20
        let eveningDate = calendar.date(from: comps)!
        #expect(HomeFeedSnapshot.timeBasedSalutation(for: "Alex", date: eveningDate) == "Good evening, Alex.")

        // Late night: 2am
        comps.hour = 2
        let lateNightDate = calendar.date(from: comps)!
        #expect(HomeFeedSnapshot.timeBasedSalutation(for: "Alex", date: lateNightDate) == "Hello, Alex.")

        // Empty name fallback
        #expect(HomeFeedSnapshot.timeBasedSalutation(for: "", date: morningDate) == "Good morning.")
    }

    @Test("ClicksSnapshot segments filter correctly")
    func testClicksFiltering() {
        let snapshot = ClicksSnapshot.preview

        let all = snapshot.filtered(by: .all)
        #expect(all.count == 6)

        let active = snapshot.filtered(by: .active)
        #expect(active.allSatisfy { $0.isOnline || $0.lastActiveRelative.contains("m ago") || $0.lastActiveRelative.contains("1h ago") })

        let encounters = snapshot.filtered(by: .encounters)
        #expect(encounters.allSatisfy { !$0.encounterLocation.isEmpty })

        let circles = snapshot.filtered(by: .circles)
        #expect(circles.allSatisfy { $0.segment == .circles })
    }

    @Test("ClicksSnapshot search query matches name, handle, location, or tags")
    func testClicksSearch() {
        let snapshot = ClicksSnapshot.preview

        let byName = snapshot.filtered(by: .all, query: "Marcus")
        #expect(byName.count == 1)
        #expect(byName.first?.displayName == "Marcus Vance")

        let byHandle = snapshot.filtered(by: .all, query: "@samirak")
        #expect(byHandle.count == 1)
        #expect(byHandle.first?.handle == "@samirak")

        let byLocation = snapshot.filtered(by: .all, query: "Dolores")
        #expect(byLocation.count == 1)

        let byTag = snapshot.filtered(by: .all, query: "Synthesizers")
        #expect(byTag.count == 1)
        #expect(byTag.first?.displayName == "Marcus Vance")
    }

    @Test("UserProfileSnapshot encodes and decodes accurately")
    func testUserProfileSnapshot() throws {
        let profile = UserProfileSnapshot.preview
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserProfileSnapshot.self, from: data)

        #expect(decoded.userId == profile.userId)
        #expect(decoded.displayName == "Alex Rivera")
        #expect(decoded.interests.count == 6)
        #expect(decoded.personalityTraits.count == 5)
        #expect(decoded.totalClicks == 28)
    }
}
