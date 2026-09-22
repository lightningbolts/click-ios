import Testing
import Foundation
@testable import Click

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Click API Client & Error Taxonomy Tests")
struct ClickAPIClientTests {
    @Test("APIError localized descriptions are user-safe and clear")
    func apiErrorDescriptions() {
        let offlineErr = APIError.offline
        #expect(offlineErr.localizedDescription.contains("offline"))

        let authErr = APIError.unauthorized
        #expect(authErr.localizedDescription.contains("expired"))

        let valErr = APIError.validation(code: "400", message: "Email format is invalid.")
        #expect(valErr.localizedDescription == "Email format is invalid.")
    }

    @Test("APIRequest constructs expected defaults")
    func apiRequestDefaults() {
        let req = APIRequest(path: "/api/ping")
        #expect(req.path == "/api/ping")
        #expect(req.method == .get)
        #expect(req.requiresAuth == true)
        #expect(req.body == nil)
        #expect(req.headers.isEmpty)
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("401 response triggers token refresher and retries request with new token")
    func tokenRefreshOn401() async throws {
        let session = makeMockSession()
        let baseURL = URL(string: "https://api.joinclick.co")!

        var attemptCount = 0
        var refreshedTokenPassed = false

        MockURLProtocol.requestHandler = { request in
            attemptCount += 1
            if attemptCount == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            } else {
                let authHeader = request.value(forHTTPHeaderField: "Authorization")
                if authHeader == "Bearer new_refreshed_token_123" {
                    refreshedTokenPassed = true
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let responseBody = """
                {"status":"success"}
                """.data(using: .utf8)!
                return (response, responseBody)
            }
        }

        final class TestBox: @unchecked Sendable {
            var refreshCalled = false
        }
        let box = TestBox()

        let client = ClickAPIClient(
            baseURL: baseURL,
            session: session,
            tokenProvider: { "expired_initial_token" },
            tokenRefresher: {
                box.refreshCalled = true
                return "new_refreshed_token_123"
            }
        )

        struct StatusResponse: Decodable {
            let status: String
        }

        let result: StatusResponse = try await client.execute(APIRequest(path: "/api/test"))
        #expect(result.status == "success")
        #expect(box.refreshCalled == true)
        #expect(attemptCount == 2)
        #expect(refreshedTokenPassed == true)

    }

    @Test("401 response throws unauthorized if token refresher fails")
    func tokenRefreshFailureThrowsUnauthorized() async {
        let session = makeMockSession()
        let baseURL = URL(string: "https://api.joinclick.co")!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = ClickAPIClient(
            baseURL: baseURL,
            session: session,
            tokenProvider: { "expired_token" },
            tokenRefresher: {
                throw APIError.unauthorized
            }
        )

        do {
            let _: (Data, HTTPURLResponse) = try await client.executeRaw(APIRequest(path: "/api/test"))
            #expect(Bool(false), "Expected executeRaw to throw unauthorized")
        } catch let error as APIError {
            if case .unauthorized = error {
                #expect(true)
            } else {
                #expect(Bool(false), "Expected APIError.unauthorized, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected APIError.unauthorized, got \(error)")
        }
    }
}

