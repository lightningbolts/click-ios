import Testing
import Foundation
@testable import Click

@Suite("Event engagement")
struct EventDetailTests {
    @Test("Check-in failures keep the server's reason")
    func checkInReasons() {
        #expect(EventEngagementRepository.checkInError(APIError.validation(code: "400", message: nil)) as? CheckInError == .locationRequired)
        #expect(EventEngagementRepository.checkInError(APIError.forbidden) as? CheckInError == .tooFar)
        #expect(EventEngagementRepository.checkInError(APIError.conflict(code: nil)) as? CheckInError == .notOpenYet)
        #expect(CheckInError.notOpenYet.localizedDescription == "Check-in opens when the event starts.")
    }

    @Test("Listing policy decodes from columns or metadata; RSVP defaults to enabled")
    func listingPolicy() {
        let row: [String: Any] = [
            "id": "e1", "beacon_type": "event", "lat": 1.0, "lng": 2.0, "approval_required": true,
            "metadata": ["event_capacity": 40, "rsvp_enabled": "false"]
        ]
        let beacon = MapBeacon.decode(row)
        #expect(beacon?.approvalRequired == true)
        #expect(beacon?.capacity == 40)
        #expect(beacon?.rsvpEnabled == false)
        #expect(MapBeacon.decode(["id": "e2", "lat": 1.0, "lng": 2.0])?.rsvpEnabled == true)
    }

    @Test("Descriptions keep inline markdown formatting")
    func markdown() {
        let rendered = BeaconDetailView.markdown("Bring **snacks** and see [site](https://joinclick.co)")
        #expect(String(rendered.characters) == "Bring snacks and see site")
        #expect(rendered.runs.contains { $0.link?.absoluteString == "https://joinclick.co" })
    }
}

@Suite("Event reminders and beacon form rules")
struct EventReminderTests {
    @Test("Reminders fire 60 and 15 minutes before, only when still ahead")
    func triggers() {
        let now = Date()
        #expect(EventReminderScheduler.triggers(start: now.addingTimeInterval(3 * 3600), now: now).map(\.minutes) == [60, 15])
        #expect(EventReminderScheduler.triggers(start: now.addingTimeInterval(30 * 60), now: now).map(\.minutes) == [15])
        #expect(EventReminderScheduler.triggers(start: now.addingTimeInterval(5 * 60), now: now).isEmpty)
    }

    @Test("Custom categories and music links")
    func formRules() {
        #expect(BeaconFormRules.customCategory("  Board games ", existing: []) == "Board games")
        #expect(BeaconFormRules.customCategory(String(repeating: "x", count: 25), existing: []) == nil)
        #expect(BeaconFormRules.customCategory("music", existing: ["Music"]) == nil)
        #expect(BeaconFormRules.isMusicLink("https://open.spotify.com/track/abc"))
        #expect(BeaconFormRules.isMusicLink("https://youtu.be/xyz"))
        #expect(!BeaconFormRules.isMusicLink("https://example.com/song"))
        #expect(!BeaconFormRules.isMusicLink("spotify:track:abc"))
    }
}
