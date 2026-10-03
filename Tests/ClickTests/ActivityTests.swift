import Testing
import Foundation
@testable import Click

@Suite("Activity inbox")
struct ActivityTests {
    private typealias Route = ClickNotificationCoordinator.TapRoute

    private func item(_ id: String, at date: Date, type: String = "reaction") -> ActivityItem {
        ActivityItem(id: id, type: type, title: "Maya reacted", body: "", data: [:], createdAt: date,
                     createdAtRaw: date.ISO8601Format(), actor: nil)
    }

    @Test("A page decodes items, actor, string data, the seen mark and the cursor")
    func decodesPage() {
        let page = ActivityRepository.decode([
            "items": [
                ["id": "a1", "type": "reaction", "title": "Maya reacted 🔥 to your drop", "body": "",
                 "data": ["type": "reaction", "target_kind": "shared_drop", "target_id": "d1", "n": 3],
                 "created_at": "2026-10-03T12:00:00.123456+00:00",
                 "actor": ["id": "u2", "name": "Maya Chen", "avatar_url": NSNull()]],
                ["id": "a2", "type": "event_reminder", "title": "Starts soon", "body": "Rooftop",
                 "data": ["type": "event_reminder", "beacon_id": "b1"], "created_at": "2026-10-03T11:00:00+00:00",
                 "actor": NSNull()],
                ["id": "bad", "type": "x", "title": "No date"],
            ],
            "seen_at": "2026-10-03T11:30:00.000Z",
            "next_before": "2026-10-03T11:00:00+00:00",
        ])
        #expect(page.items.map(\.id) == ["a1", "a2"])
        #expect(page.items[0].actor == ActivityItem.Actor(id: "u2", name: "Maya Chen", avatarURL: nil))
        #expect(page.items[0].data["n"] == "3")
        #expect(page.items[0].createdAtRaw == "2026-10-03T12:00:00.123456+00:00")
        #expect(page.items[1].actor == nil)
        #expect(page.seenAt != nil)
        #expect(page.nextBefore == "2026-10-03T11:00:00+00:00")
    }

    @Test("Newer-than compares at millisecond precision, and everything is new before a first visit")
    func newerThan() {
        let mark = Date(timeIntervalSince1970: 1_000)
        #expect(ActivityStore.isNewer(mark.addingTimeInterval(0.0004), than: mark) == false)
        #expect(ActivityStore.isNewer(mark.addingTimeInterval(0.002), than: mark))
        #expect(ActivityStore.isNewer(mark.addingTimeInterval(-60), than: mark) == false)
        #expect(ActivityStore.isNewer(mark, than: nil))
    }

    @Test("Sections: New, then Today, Yesterday, This week, This month, Earlier")
    func sections() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 14:13 UTC
        let hour: TimeInterval = 3_600
        let items = [
            item("new", at: now.addingTimeInterval(-60)),
            item("today", at: now.addingTimeInterval(-2 * hour)),
            item("yesterday", at: now.addingTimeInterval(-26 * hour)),
            item("week", at: now.addingTimeInterval(-4 * 24 * hour)),
            item("month", at: now.addingTimeInterval(-20 * 24 * hour)),
            item("earlier", at: now.addingTimeInterval(-60 * 24 * hour)),
        ]
        let sections = ActivityView.sections(items, newerThan: now.addingTimeInterval(-hour), now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["New", "Today", "Yesterday", "This week", "This month", "Earlier"])
        #expect(sections.map { $0.items.map(\.id) } == [["new"], ["today"], ["yesterday"], ["week"], ["month"], ["earlier"]])
    }

    @Test("Ages are compact")
    func ages() {
        let now = Date()
        #expect(ActivityView.age(now.addingTimeInterval(-20), now: now) == "now")
        #expect(ActivityView.age(now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(ActivityView.age(now.addingTimeInterval(-3 * 3_600), now: now) == "3h")
        #expect(ActivityView.age(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
        #expect(ActivityView.age(now.addingTimeInterval(-15 * 86_400), now: now) == "2w")
    }

    @Test("Inbox-only types open what they're about")
    func tapRoutes() {
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "reaction", "target_kind": "shared_drop", "target_id": "d1"])
                == Route.sharedDrop(dropID: "d1"))
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "reaction", "target_kind": "soundtrack", "target_id": "b1"])
                == Route.route(.beacon(beaconID: "b1")))
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "reaction"]) == Route.none)
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "event_rsvp", "beacon_id": "b1"])
                == Route.route(.event(beaconID: "b1")))
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "event_rsvp_request", "beacon_id": "b1"])
                == Route.route(.event(beaconID: "b1")))
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "event_recap", "beacon_id": "b1"])
                == Route.route(.eventRecap(beaconID: "b1")))
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "prior_connection_accepted", "peer_user_id": "u2", "connection_id": "c1"])
                == Route.route(.userProfile(userID: "u2", connectionID: "c1")))
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "prior_connection_request", "connection_id": "c1"])
                == Route.route(.activity))
    }

    @Test("The inbox opens on Home when it arrives from outside the app")
    func canonicalTab() {
        #expect(AppRoute.activity.canonicalTab == .home)
    }
}
