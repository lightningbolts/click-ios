import Foundation
import Testing
@testable import Click

@Suite("Ticket picker")
@MainActor
struct TicketPickerTests {
    /// Answers from a script; `startCheckout` can be held open to test a second tap.
    final class StubClient: TicketingClient, @unchecked Sendable {
        var offeringsQueue: [[TicketOffering]]
        var checkout: Result<CheckoutStart, Error> = .success(.fulfilled(orderID: "o1"))
        var checkoutCalls = 0
        var gate: CheckedContinuation<Void, Never>?
        var holdCheckout = false

        init(_ offerings: [TicketOffering]...) { offeringsQueue = offerings }

        func offerings(beaconID: String) async throws -> [TicketOffering] {
            offeringsQueue.count > 1 ? offeringsQueue.removeFirst() : offeringsQueue[0]
        }

        func startCheckout(beaconID: String, items: [(tierID: String, quantity: Int)]) async throws -> CheckoutStart {
            checkoutCalls += 1
            if holdCheckout { await withCheckedContinuation { gate = $0 } }
            return try checkout.get()
        }

        func order(id: String) async throws -> TicketOrder {
            TicketOrder(id: id, beaconID: "b1", outcome: .confirmed, ticketCount: 1)
        }
    }

    static func tier(_ id: String, price: Int = 1200, availability: TicketOffering.Availability = .onSale, max: Int = 4) -> TicketOffering {
        TicketOffering(id: id, name: id.uppercased(), description: nil, unitAmount: price, currency: "usd",
                       availability: availability, remaining: nil, maxQuantity: max, salesStartAt: nil)
    }

    private func loaded(_ client: StubClient) async -> TicketPickerModel {
        let model = TicketPickerModel(beaconID: "b1", client: client)
        await model.load()
        return model
    }

    @Test("Increments stop at what the buyer may take")
    func capsAtMax() async {
        let model = await loaded(StubClient([Self.tier("ga", max: 2)]))
        model.increment("ga"); model.increment("ga"); model.increment("ga")
        #expect(model.selection["ga"] == 2)
        model.decrement("ga"); model.decrement("ga"); model.decrement("ga")
        #expect((model.selection["ga"] ?? 0) == 0)
    }

    @Test("A sold-out ticket can't be picked")
    func soldOut() async {
        let model = await loaded(StubClient([Self.tier("ga", availability: .soldOut)]))
        model.increment("ga")
        #expect(model.selection["ga"] == nil)
    }

    @Test("Totals and the button read like web")
    func totals() async {
        let model = await loaded(StubClient([Self.tier("ga", price: 1200), Self.tier("vip", price: 2400)]))
        #expect(model.ctaTitle == "Get tickets")
        model.increment("ga"); model.increment("ga")
        #expect(model.total == 2400)
        #expect(model.isFree == false)
        #expect(model.ctaTitle == "Checkout · $24.00")
    }

    @Test("Free tickets are claimed, one or many")
    func freeTitle() async {
        let model = await loaded(StubClient([Self.tier("free", price: 0)]))
        model.increment("free")
        #expect(model.isFree)
        #expect(model.ctaTitle == "Claim free ticket")
        model.increment("free")
        #expect(model.ctaTitle == "Claim free tickets")
    }

    @Test("Picking a paid ticket clears free ones: they're separate orders")
    func separateKinds() async {
        let model = await loaded(StubClient([Self.tier("free", price: 0), Self.tier("ga")]))
        #expect(model.mixesKinds)
        model.increment("free")
        model.increment("ga")
        #expect(model.selection["free"] == nil)
        #expect(model.selection["ga"] == 1)
    }

    @Test("Too few left: the picker refreshes, clamps and says why")
    func inventoryConflict() async {
        let client = StubClient([Self.tier("ga", max: 4)], [Self.tier("ga", max: 1)])
        client.checkout = .failure(TicketingError(code: "insufficient_inventory", remaining: 1))
        let model = await loaded(client)
        model.increment("ga"); model.increment("ga"); model.increment("ga")
        let start = await model.submit()
        #expect(start == nil)
        #expect(model.selection["ga"] == 1)
        #expect(model.notice == "Only 1 left. We updated your selection.")
        #expect(model.phase == .ready)
    }

    @Test("A network failure keeps the selection")
    func networkFailure() async {
        let client = StubClient([Self.tier("ga")])
        client.checkout = .failure(TicketingError(code: "network"))
        let model = await loaded(client)
        model.increment("ga"); model.increment("ga")
        #expect(await model.submit() == nil)
        #expect(model.selection["ga"] == 2)
        #expect(model.phase == .failed("Check your connection and try again."))
    }

    @Test("A second tap while submitting does nothing")
    func doubleSubmit() async {
        let client = StubClient([Self.tier("ga")])
        client.holdCheckout = true
        let model = await loaded(client)
        model.increment("ga")
        let first = Task { await model.submit() }
        while client.gate == nil { await Task.yield() }
        #expect(model.phase == .submitting)
        #expect(await model.submit() == nil)
        client.gate?.resume()
        #expect(await first.value == .fulfilled(orderID: "o1"))
        #expect(client.checkoutCalls == 1)
    }

    @Test("The event button says what you can do", arguments: [
        (EventTicketing(status: "sales_open", cancelled: false, fromAmount: 1200, currency: "usd", available: true, myTicketCount: 0), "Get tickets · from $12", true),
        (EventTicketing(status: "sales_open", cancelled: false, fromAmount: 1250, currency: "usd", available: true, myTicketCount: 0), "Get tickets · from $12.50", true),
        (EventTicketing(status: "sales_open", cancelled: false, fromAmount: 0, currency: "usd", available: true, myTicketCount: 0), "Claim free tickets", true),
        (EventTicketing(status: "sales_open", cancelled: false, fromAmount: 1200, currency: "usd", available: false, myTicketCount: 0), "Sold out", false),
        (EventTicketing(status: "sales_closed", cancelled: false, fromAmount: 1200, currency: "usd", available: false, myTicketCount: 0), "Sales ended", false),
        (EventTicketing(status: "sales_paused", cancelled: false, fromAmount: 1200, currency: "usd", available: false, myTicketCount: 0), "Sales paused", false),
        (EventTicketing(status: "draft", cancelled: false, fromAmount: 1200, currency: "usd", available: false, myTicketCount: 0), "Not on sale yet", false),
        (EventTicketing(status: "sales_open", cancelled: true, fromAmount: 1200, currency: "usd", available: true, myTicketCount: 0), "Event cancelled", false),
    ])
    func buttonState(ticketing: EventTicketing, title: String, enabled: Bool) {
        let state = TicketButton.state(ticketing)
        #expect(state.title == title)
        #expect(state.enabled == enabled)
    }
}
