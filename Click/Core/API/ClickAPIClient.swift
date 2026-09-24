import Foundation

/// Primary typed networking client for Click backend APIs.
public actor ClickAPIClient {
    public let baseURL: URL
    private let session: URLSession
    private let tokenProvider: (@Sendable () async -> String?)?
    private let tokenRefresher: (@Sendable () async throws -> String)?

    public init(
        baseURL: URL,
        session: URLSession = ClickAPIClient.makeSession(),
        tokenProvider: (@Sendable () async -> String?)? = nil,
        tokenRefresher: (@Sendable () async throws -> String)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.tokenRefresher = tokenRefresher
    }

    /// Dedicated API session: waits briefly for connectivity instead of failing instantly,
    /// bounds each request at 20 s, and never serves API responses from an HTTP cache.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Transient failures worth one retry for idempotent requests.
    nonisolated static func isRetryable(_ error: APIError) -> Bool {
        switch error {
        case .timeout, .offline: true
        case .server(let status, _, _): (500...599).contains(status)
        default: false
        }
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
        try await executeRaw(request, uploadProgress: nil)
    }

    /// Like `executeRaw(_:)`; with `uploadProgress`, the body is sent as an upload task and the
    /// callback receives the fraction of request bytes sent (throttled to ~2% steps).
    public func executeRaw(_ request: APIRequest, uploadProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        #if DEBUG
        if ConnectionDebugLog.captures(path: request.path) {
            do {
                let result = try await performRaw(request, uploadProgress: uploadProgress)
                await ConnectionDebugLog.shared.record(method: request.method.rawValue, path: request.path, status: result.1.statusCode, request: request.body, response: result.0)
                return result
            } catch {
                let detail: Data? = switch error as? APIError {
                case .validation(_, let message)?, .server(_, _, let message)?: message.map { Data($0.utf8) }
                default: Data(String(describing: error).utf8)
                }
                await ConnectionDebugLog.shared.record(method: request.method.rawValue, path: request.path, status: nil, request: request.body, response: detail)
                throw error
            }
        }
        #endif
        return try await performRaw(request, uploadProgress: uploadProgress)
    }

    private func performRaw(_ request: APIRequest, uploadProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = try buildURLRequest(from: request)

        // Add authentication header if required
        if request.requiresAuth, let tokenProvider = tokenProvider {
            if let token = await tokenProvider() {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                throw APIError.unauthorized
            }
        }

        let (data, httpResponse) = try await sendRetryingOnce(urlRequest, idempotent: request.isIdempotent, uploadProgress: uploadProgress)

        // Handle 401 with single refresh + retry exactly once
        if httpResponse.statusCode == 401 && request.requiresAuth, let tokenRefresher = tokenRefresher {
            let newToken: String
            do {
                newToken = try await tokenRefresher()
            } catch let error as APIError {
                switch error {
                case .offline, .timeout, .cancelled:
                    throw error
                default:
                    throw APIError.unauthorized
                }
            } catch {
                throw APIError.unauthorized
            }

            var retryRequest = urlRequest
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await send(retryRequest, uploadProgress: uploadProgress)
            // Preserve the actual second response. A post-refresh 429/500 is not an auth error.
            return try validateResponse(data: retryData, response: retryResponse)
        }

        return try validateResponse(data: data, response: httpResponse)
    }

    private func buildURLRequest(from request: APIRequest) throws -> URLRequest {
        let base = request.baseURL ?? baseURL
        guard var components = URLComponents(url: base.appendingPathComponent(request.path), resolvingAgainstBaseURL: true) else {
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

    /// Sends once; an idempotent request that hits a transient failure (timeout, dropped
    /// connection, 5xx) is retried exactly once after a short jittered delay.
    private func sendRetryingOnce(_ urlRequest: URLRequest, idempotent: Bool, uploadProgress: (@Sendable (Double) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        guard idempotent else { return try await send(urlRequest, uploadProgress: uploadProgress) }
        do {
            let result = try await send(urlRequest)
            guard (500...599).contains(result.1.statusCode) else { return result }
        } catch let error as APIError where Self.isRetryable(error) {
            // fall through to the single retry
        }
        do {
            try await Task.sleep(for: .milliseconds(Int.random(in: 300...800)))
        } catch {
            throw APIError.cancelled
        }
        return try await send(urlRequest)
    }

    private func send(_ urlRequest: URLRequest, uploadProgress: (@Sendable (Double) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        if Task.isCancelled { throw APIError.cancelled }
        let data: Data
        let response: URLResponse

        do {
            if let uploadProgress, let body = urlRequest.httpBody {
                var uploadRequest = urlRequest
                uploadRequest.httpBody = nil
                (data, response) = try await session.upload(for: uploadRequest, from: body, delegate: UploadProgressDelegate(uploadProgress))
            } else {
                (data, response) = try await session.data(for: urlRequest)
            }
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
        } catch is CancellationError {
            throw APIError.cancelled
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

/// Reports request-body progress for one upload task.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastReported: Double = -1

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        lock.lock()
        let shouldReport = fraction - lastReported >= 0.02 || fraction >= 1
        if shouldReport { lastReported = fraction }
        lock.unlock()
        if shouldReport { onProgress(fraction) }
    }
}
