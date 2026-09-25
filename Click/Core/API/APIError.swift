import Foundation

/// Comprehensive API error taxonomy for Click networking operations.
public enum APIError: Error, LocalizedError, Equatable, Sendable {
    case offline
    case timeout
    case unauthorized
    case forbidden
    case notFound
    case conflict(code: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case validation(code: String?, message: String?)
    case server(status: Int, code: String?, message: String?)
    case decoding
    case cancelled
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "You are currently offline. Please check your internet connection."
        case .timeout:
            return "The request timed out. Please try again."
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .forbidden:
            return "You do not have permission to perform this action."
        case .notFound:
            return "The requested resource was not found."
        case .conflict(let code):
            return "A conflict occurred (\(code ?? "unknown"))."
        case .rateLimited:
            return "Too many requests. Please wait a moment and try again."
        case .validation(_, let message):
            return message ?? "Validation error. Please check your inputs."
        case .server(_, _, let message):
            return message ?? "A server error occurred. Please try again later."
        case .decoding:
            return "Unable to process the server response."
        case .cancelled:
            return "The operation was cancelled."
        case .invalidURL:
            return "Invalid request destination."
        }
    }

    public var localizedDescription: String {
        errorDescription ?? "An unexpected error occurred."
    }
}

/// One policy for URLSession transport failures, shared by the API client and Supabase Auth.
///
/// A failure while *establishing* the connection (TLS handshake, DNS, connect) means the request
/// never reached the server, so it is safe to retry for any method. Those failures are common
/// on real devices right after launch or a network hand-off (stale pooled connections), and
/// must never read as "offline" when the device is online.
enum Transport {
    /// `code` on `APIError.server` for a connection that couldn't be established.
    static let connectionFailedCode = "transport"

    static func neverReachedServer(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            true
        default:
            false
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        neverReachedServer(error) || error.code == .timedOut || error.code == .networkConnectionLost
    }

    static func map(_ error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: .offline
        case .timedOut: .timeout
        case .cancelled: .cancelled
        case .networkConnectionLost, .secureConnectionFailed, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .callIsActive:
            .server(status: error.errorCode, code: connectionFailedCode, message: "Couldn't reach Click. Try again.")
        default:
            .server(status: error.errorCode, code: nil, message: error.localizedDescription)
        }
    }

    /// Runs `operation`, retrying up to twice (250 ms, then 700 ms) when it is safe: always for
    /// connection-establishment failures, and for timeouts/dropped connections only when
    /// `idempotent`. Throws the mapped `APIError`.
    static func withRetry<T: Sendable>(idempotent: Bool, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as URLError {
                let retryable = neverReachedServer(error) || (idempotent && isTransient(error))
                guard retryable, attempt < 2, error.code != .cancelled else { throw map(error) }
                attempt += 1
                do {
                    try await Task.sleep(for: .milliseconds(attempt == 1 ? 250 : 700))
                } catch {
                    throw APIError.cancelled
                }
            } catch is CancellationError {
                throw APIError.cancelled
            }
        }
    }
}

extension Transport {
    /// For screen refreshes: one quiet retry after a short pause before a failure is surfaced
    /// ("Couldn't refresh · Retry"). Covers the dropped connection or brief path flap right after
    /// returning from background. Cancellation, auth and client errors are never retried.
    static func refreshing<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard !error.isCancellation, shouldRetryRefresh(error) else { throw error }
            ClickLog.net.info("refresh failed (\(String(describing: error), privacy: .public)); retrying once")
            do {
                try await Task.sleep(for: .milliseconds(1200))
            } catch {
                throw APIError.cancelled
            }
            return try await operation()
        }
    }

    static func shouldRetryRefresh(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .timeout, .decoding: true
        case .server(let status, _, _): status == -1 || status < 0 || (500...599).contains(status)
        case nil: !(error is DecodingError)
        default: false
        }
    }
}

