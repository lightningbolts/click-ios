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

/// A `multipart/form-data` body: text fields in order, then one file part.
public struct MultipartForm: Sendable {
    public let boundary: String
    public private(set) var body = Data()

    public init(boundary: String = "click-\(UUID().uuidString.lowercased())") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func add(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func addFile(_ name: String, fileName: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    /// The finished body with the closing boundary.
    public var encoded: Data { body + Data("--\(boundary)--\r\n".utf8) }
}

extension APIRequest {
    /// POST with a multipart body; the header overrides the client's JSON content type.
    public static func multipart(path: String, form: MultipartForm) -> APIRequest {
        APIRequest(path: path, method: .post, headers: ["Content-Type": form.contentType], body: form.encoded)
    }
}

extension APIRequest {
    /// A Supabase PostgREST RPC (`POST /rest/v1/rpc/{name}`) with the client's bearer token.
    /// `readOnly` RPCs (the default: every current one is a query) are retried after a dropped
    /// connection like a GET; the -1005 right after returning from background is common.
    public static func supabaseRPC(_ name: String, baseURL: URL, anonKey: String, body: Data, readOnly: Bool = true) -> APIRequest {
        APIRequest(baseURL: baseURL, path: "/rest/v1/rpc/\(name)", method: .post, headers: ["apikey": anonKey], body: body, idempotent: readOnly)
    }
}
