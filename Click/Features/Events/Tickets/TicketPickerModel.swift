import Foundation
import Observation

/// The ticket picker's state: what's on sale, what you picked, and the checkout it starts.
@MainActor
@Observable
final class TicketPickerModel {
    enum Phase: Equatable {
        case loading, ready, submitting
        case failed(String)
    }

    let beaconID: String
    private let client: any TicketingClient

    private(set) var offerings: [TicketOffering] = []
    /// Quantity picked per ticket type id.
    private(set) var selection: [String: Int] = [:]
    private(set) var phase: Phase = .loading
    /// Why the selection changed under you (another buyer took the last tickets, a price moved).
    private(set) var notice: String?

    init(beaconID: String, client: any TicketingClient) {
        self.beaconID = beaconID
        self.client = client
    }

    func load() async {
        if offerings.isEmpty { phase = .loading }
        do {
            try await refresh()
            phase = .ready
        } catch {
            if error.isCancellation { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func refresh() async throws {
        offerings = try await client.offerings(beaconID: beaconID)
        // Keep only what's still on sale, capped at what you may take now.
        selection = selection.reduce(into: [:]) { kept, line in
            guard let offering = offerings.first(where: { $0.id == line.key }), offering.availability == .onSale else { return }
            let quantity = min(line.value, offering.maxQuantity)
            if quantity > 0 { kept[line.key] = quantity }
        }
    }

    // MARK: - Picking

    func quantity(_ id: String) -> Int { selection[id] ?? 0 }

    func canIncrement(_ id: String) -> Bool {
        guard let offering = offerings.first(where: { $0.id == id }) else { return false }
        return offering.availability == .onSale && quantity(id) < offering.maxQuantity && phase != .submitting
    }

    func increment(_ id: String) {
        guard canIncrement(id), let offering = offerings.first(where: { $0.id == id }) else { return }
        // Free and paid tickets are separate orders (the server refuses a mix): picking one kind
        // clears the other.
        selection = selection.filter { line in offerings.first { $0.id == line.key }?.isFree == offering.isFree }
        selection[id] = quantity(id) + 1
        notice = nil
    }

    func decrement(_ id: String) {
        guard quantity(id) > 0, phase != .submitting else { return }
        selection[id] = quantity(id) > 1 ? quantity(id) - 1 : nil
    }

    // MARK: - Summary

    var count: Int { selection.values.reduce(0, +) }

    /// Minor units.
    var total: Int {
        offerings.reduce(0) { sum, offering in sum + offering.unitAmount * quantity(offering.id) }
    }

    var isFree: Bool { count > 0 && total == 0 }

    var currency: String { offerings.first?.currency ?? "usd" }

    /// Free and paid tickets are both on offer, so the sheet says they're separate orders.
    var mixesKinds: Bool { offerings.contains(where: \.isFree) && offerings.contains { !$0.isFree } }

    var ctaTitle: String {
        if count == 0 { return "Get tickets" }
        if isFree { return count == 1 ? "Claim free ticket" : "Claim free tickets" }
        return "Checkout · \(TicketPrice.money(total, currency: currency))"
    }

    // MARK: - Checkout

    /// The buyer closed Stripe's sheet: free the held tickets (a paid order refuses and stays),
    /// then show what's on sale now. The selection stays for another try.
    func checkoutClosed(orderID: String) async {
        try? await client.releaseOrder(id: orderID)
        try? await refresh()
    }

    /// Checkout couldn't be shown; the selection stays for another try.
    func report(_ error: Error) {
        phase = .failed(error.localizedDescription)
    }

    /// Starts the order. On a refusal the picker refreshes, clamps and says why; a failure to
    /// reach Click keeps the selection for another try. Ignored while one is in flight.
    func submit() async -> CheckoutStart? {
        guard phase != .submitting, count > 0 else { return nil }
        phase = .submitting
        notice = nil
        let items = offerings.compactMap { offering in
            quantity(offering.id) > 0 ? (tierID: offering.id, quantity: quantity(offering.id)) : nil
        }
        do {
            let start = try await client.startCheckout(beaconID: beaconID, items: items)
            phase = .ready
            return start
        } catch let error as TicketingError where error.code != nil && error.code != "network" {
            notice = error.localizedDescription
            try? await refresh()
            phase = .ready
            return nil
        } catch {
            phase = error.isCancellation ? .ready : .failed(error.localizedDescription)
            return nil
        }
    }
}
