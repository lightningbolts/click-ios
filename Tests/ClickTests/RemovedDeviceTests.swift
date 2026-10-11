import Foundation
import Testing
@testable import Click

/// Isolated mock transport for device registration.
final class RemovedDeviceMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var registered: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.registered.append(JSONFields.string((try? JSONFields.object(data))?["device_id"]) ?? "")
        } else if let body = request.httpBody {
            Self.registered.append(JSONFields.string((try? JSONFields.object(body))?["device_id"]) ?? "")
        }
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Removed device", .serialized)
struct RemovedDeviceTests {
    private func repository(_ vault: DeviceIdentityVault) -> ChatRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemovedDeviceMockURLProtocol.self]
        return ChatRepository(apiClient: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ), vault: vault)
    }

    @Test func aRemovedDeviceStartsOverWithANewKey() async throws {
        let vault = DeviceIdentityVault(account: "tests.removed-device.\(UUID().uuidString)")
        let removed = try vault.loadOrCreate()
        defer { try? vault.discard(try vault.loadOrCreate()) }
        RemovedDeviceMockURLProtocol.registered = []
        RemovedDeviceMockURLProtocol.handler = { _ in
            RemovedDeviceMockURLProtocol.registered.count == 1
                ? (409, #"{"error":"This device was removed from your account","code":"DEVICE_REVOKED"}"#)
                : (201, #"{"device":{}}"#)
        }

        try await repository(vault).registerDevice()

        let fresh = try vault.loadOrCreate()
        #expect(fresh.info.deviceID != removed.info.deviceID)
        #expect(RemovedDeviceMockURLProtocol.registered == [removed.info.deviceID, fresh.info.deviceID])
        // Kept in the Keychain: the next launch uses the new key.
        vault.clearCache()
        #expect(try vault.loadOrCreate().info.deviceID == fresh.info.deviceID)
    }

    @Test func makesOneNewKeyPerAttemptWhenThatIsTurnedAwayToo() async throws {
        let vault = DeviceIdentityVault(account: "tests.removed-device.\(UUID().uuidString)")
        _ = try vault.loadOrCreate()
        defer { try? vault.discard(try vault.loadOrCreate()) }
        RemovedDeviceMockURLProtocol.registered = []
        RemovedDeviceMockURLProtocol.handler = { _ in (409, #"{"error":"This device was removed from your account","code":"DEVICE_REVOKED"}"#) }

        await #expect(throws: ChatRepositoryError.currentDeviceNotRegistered) { try await repository(vault).registerDevice() }
        #expect(RemovedDeviceMockURLProtocol.registered.count == 2)
    }

    @Test func anAlreadyRegisteredDeviceKeepsItsKey() async throws {
        let vault = DeviceIdentityVault(account: "tests.removed-device.\(UUID().uuidString)")
        let identity = try vault.loadOrCreate()
        defer { try? vault.discard(identity) }
        RemovedDeviceMockURLProtocol.registered = []
        RemovedDeviceMockURLProtocol.handler = { _ in (409, #"{"error":"Device already registered"}"#) }

        try await repository(vault).registerDevice()

        #expect(try vault.loadOrCreate().info.deviceID == identity.info.deviceID)
        #expect(RemovedDeviceMockURLProtocol.registered == [identity.info.deviceID])
    }

    @Test func discardLeavesANewerIdentityAlone() throws {
        let vault = DeviceIdentityVault(account: "tests.removed-device.\(UUID().uuidString)")
        let current = try vault.loadOrCreate()
        defer { try? vault.discard(current) }

        try vault.discard(DeviceIdentityVault.DeviceIdentity(privateKey: .init()))

        vault.clearCache()
        #expect(try vault.loadOrCreate().info.deviceID == current.info.deviceID)
    }
}
