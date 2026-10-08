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

    init(orderID: String,
         fetch: @escaping (String) async throws -> TicketOrder,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.orderID = orderID
        self.fetch = fetch
        self.sleep = sleep
    }

    /// A free claim needs no wait: Click issued the tickets before answering.
    init(confirmedTicketCount: Int, orderID: String) {
        self.orderID = orderID
        self.fetch = { _ in throw CancellationError() }
        self.sleep = { _ in }
        state = .confirmed(ticketCount: confirmedTicketCount)
    }

    func run() async {
        guard state == .confirming else { return }
        var waited = Duration.zero
        while !Task.isCancelled {
            if let order = try? await fetch(orderID), let ending = Self.state(for: order) {
                state = ending
                return
            }
            let interval: Duration = waited < .seconds(10) ? .seconds(1) : .seconds(3)
            guard waited + interval <= .seconds(60) else { break }
            do { try await sleep(interval) } catch { return }
            waited += interval
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
