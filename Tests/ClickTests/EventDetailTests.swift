import Testing
import Foundation
@testable import Click

@Suite("Event engagement")
struct EventDetailTests {
    @Test("Ticket scans decode refunds, cancellations and the ticket type; anything unknown is invalid", arguments: [
        ("refunded", PassScan.Result.refunded), ("event_cancelled", .eventCancelled), ("checked_in", .checkedIn), ("something_new", .invalid),
    ])
    func ticketScan(raw: String, expected: PassScan.Result) {
        let scan = PassScan.decode(["result": raw, "tier_name": "VIP", "attendee": ["user_id": "u1", "name": "Alex Chen"]])
        #expect(scan.result == expected)
        #expect(scan.tierName == "VIP")
        #expect(scan.holder?.name == "Alex Chen")
    }

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

    @Test("Descriptions keep inline markdown formatting; links go only to the web or mail")
    func inlineMarkdown() {
        let rendered = MarkdownBlock.inline("Bring **snacks** and see [site](https://joinclick.co)")
        #expect(String(rendered.characters) == "Bring snacks and see site")
        #expect(rendered.runs.contains { $0.link?.absoluteString == "https://joinclick.co" })
        #expect(!MarkdownBlock.inline("[call](tel:5551234)").runs.contains { $0.link != nil })
    }

    @Test("Descriptions render headings, lists and quotes like the web")
    func blockMarkdown() {
        let blocks = MarkdownBlock.parse("# Run Club\n\nJoin us.\nAll paces.\n\n\n## What to bring\n\n- Shoes\n* Water\nDoors at 7.\n\n3. Warm up\n4. Run\n\n> Rain or shine\n\n#### Not a heading")
        let text = { (block: MarkdownBlock) -> String in
            switch block {
            case .heading(let level, let text): "h\(level) " + String(text.characters)
            case .paragraph(let text): String(text.characters)
            case .quote(let text): "> " + String(text.characters)
            case .list(let items): items.map { item in (item.marker.map { "\($0)" } ?? "•") + " " + String(item.text.characters) }.joined(separator: " | ")
            }
        }
        #expect(blocks.map(text) == [
            "h1 Run Club", "Join us.\nAll paces.", "h2 What to bring", "• Shoes | • Water", "Doors at 7.",
            "3 Warm up | 4 Run", "> Rain or shine", "#### Not a heading"
        ])
        #expect(MarkdownBlock.parse("**Bold** start").count == 1)
        #expect(MarkdownBlock.parse(" \n\n ").isEmpty)
    }

    @Test("Who's going names a few people and counts the rest")
    func goingNames() {
        #expect(BeaconDetailView.goingNames(["Andrew Lu", "Zakia"], more: 44, isGoing: true) == "Andrew Lu, Zakia and 44 more")
        #expect(BeaconDetailView.goingNames([], more: 3, isGoing: false) == "3 going")
        #expect(BeaconDetailView.goingNames([], more: 0, isGoing: true) == "Just you so far")
        #expect(BeaconDetailView.goingNames([], more: 0, isGoing: false) == "See who's going")
    }
}

@Suite("Event reminders and beacon form rules")
struct EventReminderTests {
    @Test("Reminders fire 60 and 15 minutes before, only when still ahead")
    func triggers() {
        let now = Date()
        #expect(EventReminderScheduler.triggers(start: now.addingTimeInterval(3 * 3600), now: now).map(\.minutes) == [60])
        #expect(EventReminderScheduler.triggers(start: now.addingTimeInterval(30 * 60), now: now).isEmpty)
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
