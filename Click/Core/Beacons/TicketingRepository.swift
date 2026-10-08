import Foundation
import Synchronization

/// What the ticket picker needs, so it can be tested without the network.
public protocol TicketingClient: Sendable {
    func offerings(beaconID: String) async throws -> [TicketOffering]
    func startCheckout(beaconID: String, items: [(tierID: String, quantity: Int)]) async throws -> CheckoutStart
    func order(id: String) async throws -> TicketOrder
}

/// Buying and holding tickets. Web owns ticketing; this client lists, buys and shows them.
/// Every refusal is thrown as a `TicketingError` carrying web's sentence.
public actor TicketingRepository: TicketingClient {
    private let api: ClickAPIClient

    public init(api: ClickAPIClient) {
        self.api = api
    }

    // MARK: - Cache

    /// Your tickets per event, so a pass opens with its QR on the first frame, offline too.
    private struct CachedTickets: Codable {
        let tickets: [OwnedTicket]
        let fetchedAt: Date
    }

    private nonisolated let ticketCache = MemoryCache<String, CachedTickets>()
    private nonisolated let owner = Mutex<String?>(nil)
    private static let persistKey = "events.tickets"

    /// Reads the signed-in user's saved tickets on the spot (before the shell's first frame).
    public nonisolated func restore(userID: String) {
        guard owner.withLock({ current in
            defer { current = userID }
            return current != userID
        }) else { return }
        ticketCache.removeAll()
        guard let stored = LocalStore.shared.load([String: CachedTickets].self, key: Self.persistKey, userID: userID)?.value else { return }
        ticketCache.fill(stored)
    }

    /// Sign-out: one account's tickets are never shown to the next.
    public nonisolated func clear() {
        owner.withLock { $0 = nil }
        ticketCache.removeAll()
    }

    public nonisolated func cachedEventTickets(beaconID: String) -> (tickets: [OwnedTicket], fetchedAt: Date)? {
        ticketCache[beaconID].map { ($0.tickets, $0.fetchedAt) }
    }

    private func persist() {
        guard let userID = owner.withLock({ $0 }) else { return }
        LocalStore.shared.save(ticketCache.all, key: Self.persistKey, userID: userID)
    }

    // MARK: - Buying

    public func offerings(beaconID: String) async throws -> [TicketOffering] {
        let root = try await object(APIRequest(path: "/api/beacons/\(beaconID)/tickets/tiers"))
        return JSONFields.rows(root["tiers"]).compactMap(TicketOffering.decode)
    }

    /// Free tickets are issued on the spot; paid ones return Stripe's page to open.
    public func startCheckout(beaconID: String, items: [(tierID: String, quantity: Int)]) async throws -> CheckoutStart {
        let body = try JSONSerialization.data(withJSONObject: [
            "items": items.map { ["ticket_tier_id": $0.tierID, "quantity": $0.quantity] },
            "client": "ios",
        ])
        let root = try await object(APIRequest(path: "/api/beacons/\(beaconID)/tickets/checkout", method: .post, body: body))
        guard let orderID = JSONFields.string(root["order_id"]) else { throw TicketingError(code: nil) }
        if let url = JSONFields.string(root["checkout_url"]).flatMap(URL.init(string:)) {
            return .checkout(orderID: orderID, url: url)
        }
        return .fulfilled(orderID: orderID)
    }

    public func order(id: String) async throws -> TicketOrder {
        let root = try await object(APIRequest(path: "/api/orders/\(id)"))
        guard let row = JSONFields.dictionary(root["order"]), let orderID = JSONFields.string(row["id"]) else {
            throw TicketingError(code: nil)
        }
        return TicketOrder(
            id: orderID,
            beaconID: JSONFields.string(row["beacon_id"]) ?? "",
            outcome: TicketOrder.outcome(orderState: JSONFields.string(row["order_state"]) ?? "",
                                         fulfillmentState: JSONFields.string(row["fulfillment_state"]) ?? ""),
            ticketCount: JSONFields.int(row["ticket_count"]) ?? 0
        )
    }

    // MARK: - Holding

    /// Your tickets for one event, newest state from the server; cached for the next open.
    public func eventTickets(beaconID: String) async throws -> [OwnedTicket] {
        let root = try await object(APIRequest(path: "/api/beacons/\(beaconID)/tickets"))
        let tickets = JSONFields.rows(root["tickets"]).compactMap(OwnedTicket.decode)
        ticketCache[beaconID] = CachedTickets(tickets: tickets, fetchedAt: .now)
        persist()
        return tickets
    }

    /// One ticket's signed Apple Wallet pass (`.pkpass` bytes).
    public func walletPass(beaconID: String, ticketID: String) async throws -> Data {
        try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/pass/wallet",
                                             queryItems: [URLQueryItem(name: "ticket", value: ticketID)])).0
    }

    /// The wallet, grouped by event.
    public func myTickets(scope: TicketScope) async throws -> [MyTicketsGroup] {
        let root = try await object(APIRequest(path: "/api/me/tickets", queryItems: [URLQueryItem(name: "scope", value: scope.rawValue)]))
        return JSONFields.rows(root["groups"]).compactMap { row in
            TicketEvent.decode(JSONFields.dictionary(row["event"])).map {
                MyTicketsGroup(event: $0, tickets: JSONFields.rows(row["tickets"]).compactMap(OwnedTicket.decode))
            }
        }
    }

    private func object(_ request: APIRequest) async throws -> [String: Any] {
        do {
            let (data, _) = try await api.executeRaw(request)
            return try JSONFields.object(data)
        } catch {
            throw TicketingError.from(error)
        }
    }
}
