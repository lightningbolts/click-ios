import Foundation
import Testing
@testable import Click

/// Isolated mock transport for the ticketing endpoints.
final class TicketingMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Ticketing", .serialized)
struct TicketingTests {
    private func repository() -> TicketingRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TicketingMockURLProtocol.self]
        return TicketingRepository(api: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ))
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        guard let stream = request.httpBodyStream else {
            return (request.httpBody.flatMap { try? JSONFields.object($0) }) ?? [:]
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return (try? JSONFields.object(data)) ?? [:]
    }

    private static let ticketJSON = #"""
    {"id":"t1","beacon_id":"b1","order_id":"o1","status":"valid","tier_name":"General admission",
     "ticket_number":"CLK-7Q2M-0001","issued_at":"2026-10-01T18:00:00Z","checked_in_at":null,
     "credential_url":"https://click.app/p/abc","code":"abc"}
    """#

    // MARK: - Decoding

    @Test("An event carries its ticketing summary; an RSVP event has none")
    func beaconTicketing() {
        let base: [String: Any] = ["id": "b1", "lat": 47.6, "lng": -122.3, "beacon_type": "event"]
        #expect(MapBeacon.decode(base)?.ticketing == nil)

        var ticketed = base
        ticketed["ticketing"] = ["status": "sales_open", "cancelled": false, "from_amount": 1200,
                                 "currency": "usd", "available": true, "my_ticket_count": 2]
        #expect(MapBeacon.decode(ticketed)?.ticketing == EventTicketing(
            status: "sales_open", cancelled: false, fromAmount: 1200, currency: "usd", available: true, myTicketCount: 2
        ))
    }

    @Test("Each availability decodes; one this build doesn't know reads as paused", arguments: [
        ("on_sale", TicketOffering.Availability.onSale), ("sold_out", .soldOut), ("not_started", .notStarted),
        ("ended", .ended), ("paused", .paused), ("something_new", .paused),
    ])
    func availability(raw: String, expected: TicketOffering.Availability) async throws {
        TicketingMockURLProtocol.handler = { _ in
            (200, #"{"tiers":[{"id":"g","name":"GA","description":null,"unit_amount":1500,"currency":"usd","availability":"\#(raw)","remaining":3,"max_quantity":4,"sales_start_at":"2026-10-03T00:00:00Z","sales_end_at":null}]}"#)
        }
        let offering = try #require(try await repository().offerings(beaconID: "b1").first)
        #expect(offering.availability == expected)
        #expect(offering.unitAmount == 1500)
        #expect(offering.remaining == 3)
        #expect(offering.maxQuantity == 4)
        #expect(offering.salesStartAt != nil)
        #expect(TicketingMockURLProtocol.requests.last?.url?.path == "/api/beacons/b1/tickets/tiers")
    }

    @Test("Order outcomes match web", arguments: [
        ("paid", "fulfilled", TicketOrder.Outcome.confirmed), ("paid", "pending", .pending),
        ("partially_refunded", "fulfilled", .confirmed), ("disputed", "fulfilled", .confirmed),
        ("refunded", "fulfilled", .refunded), ("canceled", "pending", .canceled),
        ("payment_failed", "pending", .failed), ("expired", "pending", .expired), ("awaiting_payment", "pending", .pending),
    ])
    func outcome(orderState: String, fulfillment: String, expected: TicketOrder.Outcome) {
        #expect(TicketOrder.outcome(orderState: orderState, fulfillmentState: fulfillment) == expected)
    }

    @Test("Owned tickets decode their status, number and credential")
    func ownedTickets() async throws {
        TicketingMockURLProtocol.handler = { _ in (200, "{\"tickets\":[\(Self.ticketJSON)]}") }
        let ticket = try #require(try await repository().eventTickets(beaconID: "b1").first)
        #expect(ticket.status == .valid)
        #expect(ticket.ticketNumber == "CLK-7Q2M-0001")
        #expect(ticket.code == "abc")
        #expect(ticket.checkedInAt == nil)
    }

    // MARK: - Checkout

    @Test("A free claim comes back fulfilled and posts client ios")
    func checkoutFulfilled() async throws {
        TicketingMockURLProtocol.handler = { _ in (200, #"{"order_id":"o1","status":"fulfilled"}"#) }
        let start = try await repository().startCheckout(beaconID: "b1", items: [(tierID: "g", quantity: 2)])
        #expect(start == .fulfilled(orderID: "o1"))
        let request = try #require(TicketingMockURLProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/beacons/b1/tickets/checkout")
        let body = Self.body(of: request)
        #expect(body["client"] as? String == "ios")
        let items = try #require(body["items"] as? [[String: Any]])
        #expect(items.first?["ticket_tier_id"] as? String == "g")
        #expect(items.first?["quantity"] as? Int == 2)
    }

    @Test("A paid order returns Stripe's page to open")
    func checkoutPaid() async throws {
        TicketingMockURLProtocol.handler = { _ in (200, #"{"order_id":"o2","checkout_url":"https://checkout.stripe.com/c/abc"}"#) }
        let start = try await repository().startCheckout(beaconID: "b1", items: [(tierID: "g", quantity: 1)])
        #expect(start == .checkout(orderID: "o2", url: URL(string: "https://checkout.stripe.com/c/abc")!))
    }

    @Test("Too few left: the error carries the code and how many remain")
    func insufficientInventory() async {
        TicketingMockURLProtocol.handler = { _ in (409, #"{"error":"Not enough tickets","code":"insufficient_inventory","remaining":1}"#) }
        let error = await #expect(throws: TicketingError.self) {
            try await repository().startCheckout(beaconID: "b1", items: [(tierID: "g", quantity: 3)])
        }
        #expect(error?.code == "insufficient_inventory")
        #expect(error?.remaining == 1)
        #expect(error?.errorDescription == "Only 1 left. We updated your selection.")
    }

    @Test("Refusals read as web's sentences", arguments: [
        (400, #"{"code":"mixed_order"}"#, "Get free and paid tickets in separate orders."),
        (409, #"{"code":"insufficient_inventory","remaining":0}"#, "Sold out."),
        (409, #"{"code":"sales_ended"}"#, "Sales for this event have closed."),
        (401, "{}", "Sign in to continue."),
        (400, #"{"error":"Pick at least one ticket."}"#, "Pick at least one ticket."),
        (500, "{}", "Something went wrong. Try again."),
    ])
    func messages(status: Int, body: String, expected: String) async {
        TicketingMockURLProtocol.handler = { _ in (status, body) }
        let error = await #expect(throws: TicketingError.self) {
            try await repository().startCheckout(beaconID: "b1", items: [(tierID: "g", quantity: 1)])
        }
        #expect(error?.errorDescription == expected)
    }

    @Test("A 409 keeps the server's code for every caller")
    func conflictCode() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TicketingMockURLProtocol.self]
        let api = ClickAPIClient(baseURL: URL(string: "https://api.example.com")!, session: URLSession(configuration: config), tokenProvider: { "token" })
        TicketingMockURLProtocol.handler = { _ in (409, #"{"code":"phone_taken"}"#) }
        await #expect {
            _ = try await api.executeRaw(APIRequest(path: "/api/me/phone", method: .put))
        } throws: { error in
            if case .conflict(let code, _)? = error as? APIError { return code == "phone_taken" }
            return false
        }
    }

    // MARK: - Orders and wallet

    @Test("An order reads its outcome and ticket count")
    func order() async throws {
        TicketingMockURLProtocol.handler = { _ in
            (200, #"{"order":{"id":"o1","beacon_id":"b1","order_state":"paid","fulfillment_state":"fulfilled","total_amount":3000,"ticket_count":2}}"#)
        }
        let order = try await repository().order(id: "o1")
        #expect(order == TicketOrder(id: "o1", beaconID: "b1", outcome: .confirmed, ticketCount: 2))
        #expect(TicketingMockURLProtocol.requests.last?.url?.path == "/api/orders/o1")
    }

    @Test("The wallet asks for its scope and groups tickets by event")
    func wallet() async throws {
        TicketingMockURLProtocol.handler = { _ in
            (200, "{\"groups\":[{\"event\":{\"beacon_id\":\"b1\",\"title\":\"Rooftop\",\"start_at\":\"2026-10-10T02:00:00Z\",\"end_at\":null,\"timezone\":\"America/Los_Angeles\",\"location_name\":\"The Roof\",\"image_url\":null,\"visual_seed\":\"b1\",\"cancelled\":false},\"tickets\":[\(Self.ticketJSON)]}]}")
        }
        let groups = try await repository().myTickets(scope: .past)
        #expect(groups.first?.event.title == "Rooftop")
        #expect(groups.first?.event.timeZone == "America/Los_Angeles")
        #expect(groups.first?.tickets.count == 1)
        let query = TicketingMockURLProtocol.requests.last?.url?.query ?? ""
        #expect(query.contains("scope=past"))
    }

    // MARK: - Cache

    @Test("Your tickets survive a relaunch for you and never show for someone else")
    func cachedTickets() async throws {
        let me = "test-\(UUID().uuidString)", other = "test-\(UUID().uuidString)"
        defer { LocalStore.shared.wipe(userID: me); LocalStore.shared.wipe(userID: other) }
        TicketingMockURLProtocol.handler = { _ in (200, "{\"tickets\":[\(Self.ticketJSON)]}") }

        let first = repository()
        first.restore(userID: me)
        _ = try await first.eventTickets(beaconID: "b1")
        #expect(first.cachedEventTickets(beaconID: "b1")?.tickets.count == 1)

        let relaunched = repository()
        relaunched.restore(userID: me)
        #expect(relaunched.cachedEventTickets(beaconID: "b1")?.tickets.first?.id == "t1")

        let someoneElse = repository()
        someoneElse.restore(userID: other)
        #expect(someoneElse.cachedEventTickets(beaconID: "b1") == nil)

        relaunched.clear()
        #expect(relaunched.cachedEventTickets(beaconID: "b1") == nil)
    }
}
