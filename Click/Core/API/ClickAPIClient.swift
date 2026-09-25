import Foundation
import Synchronization

/// Primary typed networking client for Click backend APIs.
public actor ClickAPIClient {
    public let baseURL: URL
    private var session: URLSession
    /// Whether the session was injected (tests) and must never be replaced.
    private let ownsSession: Bool
    private var sessionGeneration = 0
    private let tokenProvider: (@Sendable () async -> String?)?
    private let tokenRefresher: (@Sendable () async throws -> String)?

    public init(
        baseURL: URL,
        session: URLSession? = nil,
        tokenProvider: (@Sendable () async -> String?)? = nil,
        tokenRefresher: (@Sendable () async throws -> String)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session ?? Self.makeSession()
        self.ownsSession = session == nil
        self.tokenProvider = tokenProvider
        self.tokenRefresher = tokenRefresher
    }

    nonisolated static let resourceTimeout: TimeInterval = 30

    /// Bumped when the network path changes or the app returns from background: connections
    /// pooled before then are usually dead and would fail the next request with -1005.
    private nonisolated static let poolGeneration = Mutex(0)

    public nonisolated static func resetConnectionPools() {
        poolGeneration.withLock { $0 += 1 }
    }

    /// Replaces the session (dropping its connection pool) after `resetConnectionPools()`.
    private func currentSession() -> URLSession {
        let generation = Self.poolGeneration.withLock { $0 }
        if ownsSession, generation != sessionGeneration {
            sessionGeneration = generation
            session.finishTasksAndInvalidate()
            session = Self.makeSession()
        }
        return session
    }

    /// Dedicated API session: fails fast when offline (the UI shows cached data and an offline
    /// notice) rather than hanging, bounds each request at 15 s, and never serves API responses
    /// from an HTTP cache.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = resourceTimeout
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
            ClickLog.net.error("decode \(request.path, privacy: .public) as \(String(describing: T.self), privacy: .public) failed: \(String(describing: error), privacy: .public) body: \(ClickLog.excerpt(data), privacy: .private)")
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
        #if DEBUG
        let started = Date()
        do {
            let result = try await performRawUntimed(request, uploadProgress: uploadProgress)
            print("[net] \(request.method.rawValue) \(request.path) \(result.1.statusCode) \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return result
        } catch {
            if !error.isCancellation {
                ClickLog.net.error("\(request.method.rawValue, privacy: .public) \(request.path, privacy: .public) FAILED \(String(describing: error), privacy: .public) \(Int(Date().timeIntervalSince(started) * 1000))ms")
            }
            throw error
        }
        #else
        do {
            return try await performRawUntimed(request, uploadProgress: uploadProgress)
        } catch {
            if !error.isCancellation {
                ClickLog.net.error("\(request.method.rawValue, privacy: .public) \(request.path, privacy: .public) FAILED \(String(describing: error), privacy: .public)")
            }
            throw error
        }
        #endif
    }

    private func performRawUntimed(_ request: APIRequest, uploadProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = try buildURLRequest(from: request)
        #if DEBUG
        let tokenStart = Date()
        #endif

        // Add authentication header if required
        if request.requiresAuth, let tokenProvider = tokenProvider {
            if let token = await tokenProvider() {
                #if DEBUG
                let waited = Int(Date().timeIntervalSince(tokenStart) * 1000)
                if waited > 50 { print("[net] token wait \(waited)ms for \(request.path)") }
                #endif
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
                case .server(_, Transport.connectionFailedCode, _), .server(-1, _, _), .server(500...599, _, _):
                    // Couldn't reach auth: a network problem, not a revoked session.
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

    /// Identical GETs already in flight share one request (launch fans out the same reads).
    private var inFlightGETs: [String: Task<(Data, HTTPURLResponse), Error>] = [:]

    /// Sends with the shared transport retry policy; an idempotent 5xx is retried once.
    private func sendRetryingOnce(_ urlRequest: URLRequest, idempotent: Bool, uploadProgress: (@Sendable (Double) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        if urlRequest.httpMethod == "GET", uploadProgress == nil, let key = Self.coalescingKey(urlRequest) {
            if let running = inFlightGETs[key] { return try await running.value }
            let task = Task { try await self.sendWithPolicy(urlRequest, idempotent: idempotent, uploadProgress: nil) }
            inFlightGETs[key] = task
            defer { inFlightGETs[key] = nil }
            return try await task.value
        }
        return try await sendWithPolicy(urlRequest, idempotent: idempotent, uploadProgress: uploadProgress)
    }

    nonisolated static func coalescingKey(_ request: URLRequest) -> String? {
        guard let url = request.url?.absoluteString else { return nil }
        return url + "|" + (request.value(forHTTPHeaderField: "Authorization") ?? "")
    }

    private func sendWithPolicy(_ urlRequest: URLRequest, idempotent: Bool, uploadProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let first = try await send(urlRequest, idempotent: idempotent, uploadProgress: uploadProgress)
        guard idempotent, (500...599).contains(first.1.statusCode) else { return first }
        do {
            try await Task.sleep(for: .milliseconds(Int.random(in: 300...800)))
        } catch {
            throw APIError.cancelled
        }
        return try await send(urlRequest, idempotent: idempotent, uploadProgress: uploadProgress)
    }

    private func send(_ urlRequest: URLRequest, idempotent: Bool = false, uploadProgress: (@Sendable (Double) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        if Task.isCancelled { throw APIError.cancelled }
        let session = currentSession()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Transport.withRetry(idempotent: idempotent) {
                if let uploadProgress, let body = urlRequest.httpBody {
                    var uploadRequest = urlRequest
                    uploadRequest.httpBody = nil
                    return try await session.upload(for: uploadRequest, from: body, delegate: UploadProgressDelegate(uploadProgress))
                }
                return try await session.data(for: urlRequest)
            }
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
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
