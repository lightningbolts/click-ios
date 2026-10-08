import Foundation

/// An event's ticketing at a glance, as `GET /api/beacons/:id` sends it. A ticket replaces the RSVP.
public struct EventTicketing: Equatable, Hashable, Sendable, Codable {
    /// `draft`, `ready`, `sales_open`, `sales_paused` or `sales_closed`.
    public let status: String
    public let cancelled: Bool
    /// The cheapest ticket in minor units, `nil` when nothing is listed.
    public let fromAmount: Int?
    public let currency: String
    /// Something is on sale right now.
    public let available: Bool
    /// Live tickets the viewer holds (0 when signed out).
    public let myTicketCount: Int

    public init(status: String, cancelled: Bool, fromAmount: Int?, currency: String, available: Bool, myTicketCount: Int) {
        self.status = status
        self.cancelled = cancelled
        self.fromAmount = fromAmount
        self.currency = currency
        self.available = available
        self.myTicketCount = myTicketCount
    }

    static func decode(_ row: [String: Any]?) -> EventTicketing? {
        guard let row, let status = JSONFields.string(row["status"]) else { return nil }
        return EventTicketing(
            status: status,
            cancelled: JSONFields.bool(row["cancelled"]) ?? false,
            fromAmount: JSONFields.int(row["from_amount"]),
            currency: JSONFields.string(row["currency"]) ?? "usd",
            available: JSONFields.bool(row["available"]) ?? false,
            myTicketCount: JSONFields.int(row["my_ticket_count"]) ?? 0
        )
    }
}

/// A ticket type as a buyer sees it.
public struct TicketOffering: Identifiable, Equatable, Sendable, Codable {
    public enum Availability: String, Sendable, Codable {
        case onSale = "on_sale", soldOut = "sold_out", notStarted = "not_started", ended, paused
    }

    public let id: String
    public let name: String
    public let description: String?
    /// Minor units; 0 is free.
    public let unitAmount: Int
    public let currency: String
    public let availability: Availability
    /// Only when 10 or fewer are left.
    public let remaining: Int?
    /// Most the viewer can pick now (order limit, stock and per-person limit combined).
    public let maxQuantity: Int
    public let salesStartAt: Date?

    public var isFree: Bool { unitAmount == 0 }

    static func decode(_ row: [String: Any]) -> TicketOffering? {
        guard let id = JSONFields.string(row["id"]), let name = JSONFields.string(row["name"]) else { return nil }
        return TicketOffering(
            id: id,
            name: name,
            description: JSONFields.string(row["description"]),
            unitAmount: JSONFields.int(row["unit_amount"]) ?? 0,
            currency: JSONFields.string(row["currency"]) ?? "usd",
            // A state this build doesn't know can't be bought, so it reads as paused.
            availability: JSONFields.string(row["availability"]).flatMap(Availability.init(rawValue:)) ?? .paused,
            remaining: JSONFields.int(row["remaining"]),
            maxQuantity: JSONFields.int(row["max_quantity"]) ?? 0,
            salesStartAt: JSONFields.date(row["sales_start_at"])
        )
    }
}

/// A ticket as its owner sees it. The credential is present only while the ticket admits.
public struct OwnedTicket: Identifiable, Equatable, Sendable, Codable {
    public enum Status: String, Sendable, Codable {
        case valid, checkedIn = "checked_in", refunded, void
    }

    public let id: String
    public let beaconID: String
    public let orderID: String
    public let status: Status
    public let tierName: String
    public let ticketNumber: String
    public let checkedInAt: Date?
    public let credentialURL: String?
    public let code: String?

    static func decode(_ row: [String: Any]) -> OwnedTicket? {
        guard let id = JSONFields.string(row["id"]),
              let beaconID = JSONFields.string(row["beacon_id"]),
              let status = JSONFields.string(row["status"]).flatMap(Status.init(rawValue:)) else { return nil }
        return OwnedTicket(
            id: id,
            beaconID: beaconID,
            orderID: JSONFields.string(row["order_id"]) ?? "",
            status: status,
            tierName: JSONFields.string(row["tier_name"]) ?? "Ticket",
            ticketNumber: JSONFields.string(row["ticket_number"]) ?? "",
            checkedInAt: JSONFields.date(row["checked_in_at"]),
            credentialURL: JSONFields.string(row["credential_url"]),
            code: JSONFields.string(row["code"])
        )
    }
}

/// The event a wallet group belongs to.
public struct TicketEvent: Equatable, Sendable, Codable {
    public let beaconID: String
    public let title: String
    public let startAt: Date?
    public let endAt: Date?
    public let timeZone: String?
    public let locationName: String?
    public let imageURL: String?
    public let visualSeed: String
    public let cancelled: Bool

    static func decode(_ row: [String: Any]?) -> TicketEvent? {
        guard let row, let id = JSONFields.string(row["beacon_id"]) else { return nil }
        return TicketEvent(
            beaconID: id,
            title: JSONFields.string(row["title"]) ?? "Event",
            startAt: JSONFields.date(row["start_at"]),
            endAt: JSONFields.date(row["end_at"]),
            timeZone: JSONFields.string(row["timezone"]),
            locationName: JSONFields.string(row["location_name"]),
            imageURL: JSONFields.string(row["image_url"]),
            visualSeed: JSONFields.string(row["visual_seed"]) ?? id,
            cancelled: JSONFields.bool(row["cancelled"]) ?? false
        )
    }
}

public struct MyTicketsGroup: Equatable, Sendable, Codable {
    public let event: TicketEvent
    public let tickets: [OwnedTicket]
}

public enum TicketScope: String, Sendable {
    case upcoming, past
}

/// What the buyer sees after checkout. Webhooks, not the return from Stripe, decide this.
public struct TicketOrder: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case confirmed, pending, canceled, failed, expired, refunded
    }

    public let id: String
    public let beaconID: String
    public let outcome: Outcome
    public let ticketCount: Int

    /// Mirrors web `orderOutcome`.
    static func outcome(orderState: String, fulfillmentState: String) -> Outcome {
        switch orderState {
        case "paid", "partially_refunded", "disputed": fulfillmentState == "fulfilled" ? .confirmed : .pending
        case "refunded": .refunded
        case "canceled": .canceled
        case "payment_failed": .failed
        case "expired": .expired
        default: .pending
        }
    }
}

public enum CheckoutStart: Equatable, Sendable {
    /// Free tickets: issued already.
    case fulfilled(orderID: String)
    /// Paid tickets: Stripe's hosted page to open.
    case checkout(orderID: String, url: URL)
}

/// A refused or failed ticketing request, worded as web words it.
public struct TicketingError: LocalizedError, Equatable, Sendable {
    public let code: String?
    public let remaining: Int?
    /// The server's own sentence, shown when the code has no local copy.
    public let serverMessage: String?
    let signedOut: Bool

    public init(code: String?, remaining: Int? = nil, serverMessage: String? = nil, signedOut: Bool = false) {
        self.code = code
        self.remaining = remaining
        self.serverMessage = serverMessage
        self.signedOut = signedOut
    }

    private static let messages: [String: String] = [
        "network": "Check your connection and try again.",
        "price_changed": "The price changed. Check the new total.",
        "sales_ended": "Sales for this event have closed.",
        "sales_not_open": "Sales for this event have closed.",
        "sales_not_started": "Sales haven’t started yet.",
        "over_user_limit": "You’ve reached the ticket limit for this event.",
        "over_order_limit": "That’s more tickets than one order allows.",
        "tier_inactive": "That ticket isn’t available anymore.",
        "tier_not_found": "That ticket isn’t available anymore.",
        "event_cancelled": "This event was cancelled.",
        "organizer_not_ready": "Tickets aren’t on sale yet.",
        "mixed_order": "Get free and paid tickets in separate orders.",
    ]

    public var errorDescription: String? {
        if code == "insufficient_inventory" {
            guard let remaining, remaining > 0 else { return "Sold out." }
            return "Only \(remaining) left. We updated your selection."
        }
        if let code, let message = Self.messages[code] { return message }
        if signedOut { return "Sign in to continue." }
        return serverMessage ?? "Something went wrong. Try again."
    }

    /// Reads the server's `{error, code, remaining}` body out of a client error.
    static func from(_ error: Error) -> Error {
        if error.isCancellation { return error }
        guard let apiError = error as? APIError else { return error }
        switch apiError {
        case .offline, .timeout:
            return TicketingError(code: "network")
        case .unauthorized:
            return TicketingError(code: nil, signedOut: true)
        case .conflict(let code, let body):
            let fields = body.flatMap { try? JSONFields.object(Data($0.utf8)) } ?? [:]
            return TicketingError(code: code ?? JSONFields.string(fields["code"]), remaining: JSONFields.int(fields["remaining"]),
                                  serverMessage: JSONFields.string(fields["error"]))
        case .validation(_, let body):
            let fields = body.flatMap { try? JSONFields.object(Data($0.utf8)) } ?? [:]
            return TicketingError(code: JSONFields.string(fields["code"]), remaining: JSONFields.int(fields["remaining"]),
                                  serverMessage: JSONFields.string(fields["error"]))
        default:
            return TicketingError(code: nil)
        }
    }
}
