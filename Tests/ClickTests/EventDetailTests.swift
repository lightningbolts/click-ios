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
