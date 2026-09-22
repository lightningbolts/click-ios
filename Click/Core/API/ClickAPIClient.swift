import Foundation

/// Primary typed networking client for Click backend APIs.
public actor ClickAPIClient {
    public let baseURL: URL
    private let session: URLSession
    private let tokenProvider: (@Sendable () async -> String?)?
    private let tokenRefresher: (@Sendable () async throws -> String)?

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: (@Sendable () async -> String?)? = nil,
        tokenRefresher: (@Sendable () async throws -> String)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.tokenRefresher = tokenRefresher
    }

    /// Executes an API request and decodes the expected response model.
    public func execute<T: Decodable>(_ request: APIRequest) async throws -> T {
        let (data, _) = try await executeRaw(request)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .useDefaultKeys
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    /// Executes an API request and returns the raw response data.
    public func executeRaw(_ request: APIRequest) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = try buildURLRequest(from: request)

        // Add authentication header if required
        if request.requiresAuth, let tokenProvider = tokenProvider {
            if let token = await tokenProvider() {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                throw APIError.unauthorized
            }
        }

        let (data, httpResponse) = try await send(urlRequest)

        // Handle 401 with single refresh + retry exactly once
        if httpResponse.statusCode == 401 && request.requiresAuth, let tokenRefresher = tokenRefresher {
            do {
                let newToken = try await tokenRefresher()
                var retryRequest = urlRequest
                retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await send(retryRequest)
                return try validateResponse(data: retryData, response: retryResponse)
            } catch {
                throw APIError.unauthorized
            }
        }

        return try validateResponse(data: data, response: httpResponse)
    }

    private func buildURLRequest(from request: APIRequest) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(request.path), resolvingAgainstBaseURL: true) else {
            throw APIError.invalidURL
        }

        if !request.queryItems.isEmpty {
            components.queryItems = request.queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body

        // Standard Request Headers
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("ios", forHTTPHeaderField: "X-Client-Platform")
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")

        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Custom Headers
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        return urlRequest
    }

    private func send(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw APIError.offline
            case .timedOut:
                throw APIError.timeout
            case .cancelled:
                throw APIError.cancelled
            default:
                throw APIError.server(status: urlError.errorCode, code: nil, message: urlError.localizedDescription)
            }
        } catch {
            throw APIError.server(status: -1, code: nil, message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.server(status: -1, code: nil, message: "Non-HTTP response")
        }

        return (data, httpResponse)
    }

    private func validateResponse(data: Data, response: HTTPURLResponse) throws -> (Data, HTTPURLResponse) {
        switch response.statusCode {
        case 200...299:
            return (data, response)
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 409:
            throw APIError.conflict(code: nil)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        case 400, 422:
            let message = String(data: data, encoding: .utf8)
            throw APIError.validation(code: String(response.statusCode), message: message)
        case 500...599:
            let message = String(data: data, encoding: .utf8)
            throw APIError.server(status: response.statusCode, code: nil, message: message)
        default:
            throw APIError.server(status: response.statusCode, code: nil, message: "Unexpected status code \(response.statusCode)")
        }
    }
}
