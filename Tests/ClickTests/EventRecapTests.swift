import Foundation
import Testing
import UIKit
@testable import Click

@MainActor
@Suite("Event recap")
struct EventRecapTests {
    /// A recap whose drops are already cached, as when it opens from the event page.
    private func model(_ drops: [[String: Any]]) -> EventRecapModel {
        let env = AppEnvironment(network: NetworkMonitor(start: false))
        let state = EventDropsState.parse(["state": "revealed", "event_title": "Rooftop", "access": "participant", "drops": drops])
        env.beaconExtras.seed(state, for: BeaconExtrasCache.eventDrops("b1"))
        return EventRecapModel(beaconID: "b1", env: env)
    }

    private func drop(_ id: String, _ user: String, minute: Int, mine: Bool = false, developed: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "user": ["id": user, "name": user.capitalized], "is_mine": mine,
            "created_at": "2026-10-08T23:\(String(format: "%02d", minute)):00Z",
            "original_url": "https://cdn.example.com/\(id).jpg", "width": 3, "height": 4,
        ]
        if developed { row["developed_at"] = "2026-10-09T09:00:00Z" }
        return row
    }

    @Test("The grid runs as the drops were taken; the story goes person by person, yours first")
    func order() {
        let recap = model([
            drop("k2", "kai", minute: 30),
            drop("m1", "me", minute: 20, mine: true),
            drop("k1", "kai", minute: 5, developed: true),
            drop("j1", "jo", minute: 10),
        ])
        #expect(recap.timeline.map(\.id) == ["k1", "j1", "m1", "k2"])
        #expect(recap.chapterKeys == ["me", "kai", "jo"])
        #expect(recap.chapter("kai") == ["k1", "k2"])
        #expect(recap.chapterKey(of: "k2") == "kai")
    }

    @Test("A person's story opens on their first drop still to develop")
    func chapterStart() {
        let recap = model([
            drop("k1", "kai", minute: 5, developed: true),
            drop("k2", "kai", minute: 30),
            drop("j1", "jo", minute: 10, developed: true),
        ])
        #expect(recap.chapterStart("kai") == "k2")
        #expect(recap.chapterStart("jo") == "j1")
        #expect(recap.hasUndeveloped)
    }

    @Test("An undeveloped drop waits for its tap and shows no photo; its look shows once developed")
    func undeveloped() {
        let recap = model([drop("a", "kai", minute: 1), drop("b", "kai", minute: 2, developed: true)])
        #expect(!recap.isDeveloped("a"))
        #expect(recap.tapDevelops("a"))
        #expect(recap.cachedPhoto("a") == nil)
        #expect(recap.thumb("a") == nil)
        #expect(recap.status("a").title == "Tap to develop")
        #expect(recap.page("a")?.subtitle?.contains("·") == false)

        #expect(recap.isDeveloped("b"))
        #expect(!recap.tapDevelops("b"))
        #expect(recap.page("b")?.subtitle?.contains("·") == true)
        #expect(recap.page("b")?.aspect == 0.75)
        recap.natural = true
        #expect(recap.page("b")?.subtitle?.contains("·") == false)
    }

    @Test("The photo cache keeps the most recently used")
    func cacheEvicts() {
        var cache = RecapPhotoCache(limit: 2)
        let photo = RecapPhoto(natural: UIImage(), look: UIImage())
        cache.insert(photo, for: "a")
        cache.insert(photo, for: "b")
        cache.insert(photo, for: "a")
        cache.insert(photo, for: "c")
        #expect(cache["a"] != nil)
        #expect(cache["b"] == nil)
        #expect(cache["c"] != nil)
    }
}
