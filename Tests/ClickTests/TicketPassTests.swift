import Foundation
import Testing
@testable import Click

@Suite("Ticket pass")
struct TicketPassTests {
    static let checkedIn = Date(timeIntervalSince1970: 1_790_000_000)

    static func ticket(_ status: OwnedTicket.Status, checkedInAt: Date? = nil) -> OwnedTicket {
        OwnedTicket(id: "t1", beaconID: "b1", orderID: "o1", status: status, tierName: "General admission",
                    ticketNumber: "CLK-7Q2M-0001", checkedInAt: checkedInAt,
                    credentialURL: status == .valid ? "https://joinclick.co/p/abc" : nil, code: status == .valid ? "abc" : nil)
    }

    @Test("Each ticket shows its QR or why not", arguments: [
        (ticket(.valid), false, TicketDisplay.qr),
        (ticket(.checkedIn, checkedInAt: checkedIn), false, .checkedIn(checkedIn)),
        (ticket(.refunded), false, .refunded),
        (ticket(.void), false, .void),
        (ticket(.valid), true, .cancelled),
        (ticket(.checkedIn, checkedInAt: checkedIn), true, .cancelled),
        (ticket(.refunded), true, .cancelled),
    ])
    func display(ticket: OwnedTicket, cancelled: Bool, expected: TicketDisplay) {
        #expect(TicketPassContent.ticketDisplay(ticket, cancelled: cancelled) == expected)
    }

    @Test("A valid ticket without a credential can't show a QR")
    func missingCredential() {
        let ticket = OwnedTicket(id: "t1", beaconID: "b1", orderID: "o1", status: .valid, tierName: "GA",
                                 ticketNumber: "CLK-1", checkedInAt: nil, credentialURL: nil, code: nil)
        #expect(TicketPassContent.ticketDisplay(ticket, cancelled: false) == .void)
    }

    @Test("Stale tickets say when they were last updated", arguments: [
        (30.0, nil as String?), (90.0, "Updated 1 min ago"), (7200.0, "Updated 2 hr ago"),
    ])
    func staleness(age: TimeInterval, expected: String?) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TicketPassContent.updatedLine(fetchedAt: now.addingTimeInterval(-age), now: now) == expected)
    }
}
