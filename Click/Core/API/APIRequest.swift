import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Represents an outgoing HTTP request specification to Click backend endpoints.
public struct APIRequest: Sendable {
    /// Overrides the client's base URL. Used only for approved Supabase read RPCs, which share
    /// the client's bearer injection and single refresh-and-retry path.
    public let baseURL: URL?
    public let path: String
    public let method: HTTPMethod
    public let queryItems: [URLQueryItem]
    public let headers: [String: String]
    public let body: Data?
    public let requiresAuth: Bool
    /// Safe to repeat after a transient failure. GETs are idempotent by default; PUT/DELETE
    /// callers opt in explicitly. POST/PATCH are never retried automatically.
    public let isIdempotent: Bool

    public init(
        baseURL: URL? = nil,
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        requiresAuth: Bool = true,
        idempotent: Bool? = nil
    ) {
        self.baseURL = baseURL
        self.path = path
        self.method = method
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.requiresAuth = requiresAuth
        self.isIdempotent = idempotent ?? (method == .get)
    }

    /// Cheap authenticated reachability probe (same route the KMP client uses).
    public static let ping = APIRequest(path: "/api/ping")
}
