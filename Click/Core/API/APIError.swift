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
