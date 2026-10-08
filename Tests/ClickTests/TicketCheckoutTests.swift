import Foundation
import Testing
@testable import Click

@Suite("Ticket checkout")
@MainActor
struct TicketCheckoutTests {
    @Test("Stripe's return carries the order; a cancel says so", arguments: [
        ("https://joinclick.co/e/b1/tickets/return?order=X", CheckoutReturn.completed(orderID: "X")),
        ("https://joinclick.co/e/b1/tickets/return?order=X&canceled=1", .canceled),
        ("https://joinclick.co/e/b1/tickets/return", .canceled),
    ])
    func callback(url: String, expected: CheckoutReturn) {
        #expect(TicketCheckout.parse(callback: URL(string: url)!) == expected)
    }

    @Test("The return path is the one web sends Stripe back to")
    func returnPath() {
        #expect(TicketCheckout.returnPath(beaconID: "b1") == "/e/b1/tickets/return")
    }

    /// Answers each poll from a script (the last answer repeats) and records the waits.
    final class Script: @unchecked Sendable {
        var outcomes: [TicketOrder.Outcome]
        var polls = 0
        var waited: [Duration] = []
        init(_ outcomes: [TicketOrder.Outcome]) { self.outcomes = outcomes }

        func fetch(_ id: String) async throws -> TicketOrder {
            polls += 1
            let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
            return TicketOrder(id: id, beaconID: "b1", outcome: outcome, ticketCount: 2)
        }
    }

    private func model(_ script: Script) -> OrderConfirmationModel {
        OrderConfirmationModel(orderID: "o1", fetch: script.fetch, sleep: { script.waited.append($0) })
    }

    @Test("Pending a few times, then confirmed")
    func confirms() async {
        let script = Script([.pending, .pending, .pending, .confirmed])
        let model = model(script)
        await model.run()
        #expect(model.state == .confirmed(ticketCount: 2))
        #expect(script.polls == 4)
        #expect(script.waited == [.seconds(1), .seconds(1), .seconds(1)])
    }

    @Test("Pending forever: polls every second for 10 s, then every 3 s, and stops at 60 s")
    func givesUp() async {
        let script = Script([.pending])
        let model = model(script)
        await model.run()
        #expect(model.state == .stillConfirming)
        #expect(script.waited.prefix(10).allSatisfy { $0 == .seconds(1) })
        #expect(script.waited.dropFirst(10).allSatisfy { $0 == .seconds(3) })
        let total = script.waited.reduce(Duration.zero, +)
        #expect(total <= .seconds(60))
        #expect(total > .seconds(57))
    }

    @Test("Each ending reads as web's return page", arguments: [
        (TicketOrder.Outcome.canceled, OrderConfirmationModel.State.canceled),
        (.failed, .failed), (.expired, .expired), (.refunded, .refunded),
    ])
    func endings(outcome: TicketOrder.Outcome, expected: OrderConfirmationModel.State) async {
        let model = model(Script([outcome]))
        await model.run()
        #expect(model.state == expected)
    }

    @Test("A dropped poll is retried, not shown as a failure")
    func transientError() async {
        final class Flaky: @unchecked Sendable {
            var calls = 0
            func fetch(_ id: String) async throws -> TicketOrder {
                calls += 1
                if calls == 1 { throw TicketingError(code: "network") }
                return TicketOrder(id: id, beaconID: "b1", outcome: .confirmed, ticketCount: 1)
            }
        }
        let flaky = Flaky()
        let model = OrderConfirmationModel(orderID: "o1", fetch: flaky.fetch, sleep: { _ in })
        await model.run()
        #expect(model.state == .confirmed(ticketCount: 1))
    }
}
