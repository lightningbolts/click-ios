import AuthenticationServices
import Foundation
import Observation

public enum CheckoutReturn: Equatable, Sendable {
    case completed(orderID: String)
    case canceled
}

/// Stripe's hosted checkout in a web sheet that closes itself when Stripe sends the buyer back to
/// Click's return page. The return only says the buyer finished; webhooks decide the order.
@MainActor
enum TicketCheckout {
    /// Must match web `eventTicketsReturnPath`.
    static func returnPath(beaconID: String) -> String { "/e/\(beaconID)/tickets/return" }

    static func parse(callback: URL) -> CheckoutReturn {
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "canceled" })?.value != "1",
              let order = query.first(where: { $0.name == "order" })?.value, !order.isEmpty else { return .canceled }
        return .completed(orderID: order)
    }

    /// Closing the sheet reads as `.canceled`, so the picker keeps the selection.
    static func run(url: URL, beaconID: String, host: String = AppConfig.shared.apiBaseURL.host() ?? "joinclick.co") async throws -> CheckoutReturn {
        do {
            let callback = try await WebAuthPresenter.present(
                url,
                callback: .https(host: host, path: returnPath(beaconID: beaconID)),
                startFailure: TicketingError(code: nil)
            )
            return parse(callback: callback)
        } catch is CancellationError {
            return .canceled
        }
    }
}

/// Waits for Click to confirm an order: every second for 10 s, then every 3 s, giving up at 60 s
/// (the payment may still clear; the tickets then show on the event page).
@MainActor
@Observable
final class OrderConfirmationModel {
    enum State: Equatable {
        case confirming
        case confirmed(ticketCount: Int)
        case canceled, failed, expired, refunded, stillConfirming
    }

    private(set) var state: State = .confirming
    let orderID: String
    private let fetch: (String) async throws -> TicketOrder
    private let sleep: (Duration) async throws -> Void
    private let now: () -> Date

    init(orderID: String,
         fetch: @escaping (String) async throws -> TicketOrder,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> Date = Date.init) {
        self.orderID = orderID
        self.fetch = fetch
        self.sleep = sleep
        self.now = now
    }

    /// A free claim needs no wait: Click issued the tickets before answering.
    init(confirmedTicketCount: Int, orderID: String) {
        self.orderID = orderID
        self.fetch = { _ in throw CancellationError() }
        self.sleep = { _ in }
        self.now = Date.init
        state = .confirmed(ticketCount: confirmedTicketCount)
    }

    func run() async {
        guard state == .confirming else { return }
        let start = now()
        while !Task.isCancelled {
            do {
                if let ending = Self.state(for: try await fetch(orderID)) {
                    state = ending
                    return
                }
            } catch let error as TicketingError where error.code == "not_found" {
                break // not this buyer's order (or gone): waiting won't change that
            } catch {
                // A dropped poll: try again.
            }
            let waited = now().timeIntervalSince(start)
            let interval: Duration = waited < 10 ? .seconds(1) : .seconds(3)
            guard waited + TimeInterval(interval.components.seconds) <= 60 else { break }
            do { try await sleep(interval) } catch { return }
        }
        if !Task.isCancelled { state = .stillConfirming }
    }

    private static func state(for order: TicketOrder) -> State? {
        switch order.outcome {
        case .confirmed: .confirmed(ticketCount: order.ticketCount)
        case .pending: nil
        case .canceled: .canceled
        case .failed: .failed
        case .expired: .expired
        case .refunded: .refunded
        }
    }
}
