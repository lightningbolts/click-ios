import Testing
import Foundation
import CryptoKit
@testable import Click

/// Email-approved chat history for the user's newer devices: an older device wraps the historical
/// epoch keys it holds for the new device (see `ChatRepository.shareHistoryWithApprovedDevices`).
@Suite("Device history sharing")
struct DeviceHistoryShareTests {
    private let chatID = "11111111-1111-4111-8111-111111111111"

    @Test("Wraps only held epochs, once each, in order")
    func wrapsHeldEpochsInOrder() throws {
        var wrapped: [ClickCryptoV2.EpochKeyWrapMetadata] = []
        let envelopes = try ChatRepository.historyEnvelopes(
            chatID: chatID,
            epochs: [2, 1, 2, 5],
            recipientDeviceID: "new-device",
            recipientPublicKey: "recipient-spki",
            senderDeviceID: "old-device",
            epochKeys: [1: Data(repeating: 1, count: 32), 2: Data(repeating: 2, count: 32)]
        ) { metadata, _, recipientKey in
            #expect(recipientKey == "recipient-spki")
            wrapped.append(metadata)
            return "e2e2:epoch-\(metadata.epoch)"
        }

        #expect(envelopes.map(\.epoch) == [1, 2])
        #expect(envelopes.allSatisfy { $0.recipientDeviceID == "new-device" && $0.senderDeviceID == "old-device" })
        #expect(wrapped.first == ClickCryptoV2.EpochKeyWrapMetadata(
            chatId: chatID, epoch: 1, senderDeviceId: "old-device", recipientDeviceId: "new-device"
        ))
    }

    @Test("The recipient device can unwrap a shared history key")
    func recipientUnwrapsSharedKey() throws {
        let epochKey = try ClickCryptoV2.generateEpochKey()
        let recipientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let recipient = DeviceIdentityVault.DeviceIdentity(privateKey: recipientPrivateKey)

        let envelope = try #require(try ChatRepository.historyEnvelopes(
            chatID: chatID,
            epochs: [1],
            recipientDeviceID: recipient.info.deviceID,
            recipientPublicKey: recipient.info.publicKeySpkiBase64,
            senderDeviceID: "old-device",
            epochKeys: [1: epochKey]
        ).first)

        let unwrapped = try ClickCryptoV2.unwrapEpochKey(
            metadata: .init(chatId: chatID, epoch: 1, senderDeviceId: "old-device", recipientDeviceId: recipient.info.deviceID),
            recipientPrivateKey: recipientPrivateKey,
            envelope: envelope.envelope
        )
        #expect(unwrapped == epochKey)
    }

    @Test("Missing epochs lists only v2 epochs this device lacks")
    func missingEpochs() throws {
        func wire(_ epoch: Int) throws -> String {
            try ClickCryptoV2.encryptMessage(
                metadata: .init(chatId: chatID, epoch: epoch, senderDeviceId: "device-1", clientMessageId: UUID().uuidString.lowercased()),
                epochKey: try ClickCryptoV2.generateEpochKey(),
                plaintext: "hi"
            )
        }
        let contents = [try wire(1), try wire(2), try wire(3), "plain text", "e2e:legacy"]
        #expect(ChatRepository.missingEpochs(in: contents, held: [3]) == [1, 2])
        #expect(ChatRepository.missingEpochs(in: contents, held: [1, 2, 3]).isEmpty)
    }

    @Test("A device-approval challenge wrapped by click-web unwraps on iOS to the original bytes")
    func approvalChallengeInterop() throws {
        // Produced by click-web's wrapEpochKey (lib/server/deviceApproval.ts uses it unchanged).
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: "cDTzJNWtViwSUkyhdLJIOg6fyxudPR3gU53r3S3V43k=")!)
        let envelope = "e2e2:eyJjaGF0SWQiOiJhcHByb3ZhbDoxMTExMTExMS0xMTExLTQxMTEtODExMS0xMTExMTExMTExMTEiLCJlcG9jaCI6MSwic2VuZGVyRGV2aWNlSWQiOiJjbGljay1kZXZpY2UtYXBwcm92YWwiLCJyZWNpcGllbnREZXZpY2VJZCI6InBob25lLWRldiIsInYiOjIsInR5cGUiOiJlcG9jaC1rZXktd3JhcCIsImNyeXB0b1ZlcnNpb24iOjIsImVwaGVtZXJhbFB1YmxpY0tleSI6Ik1Db3dCUVlESzJWdUF5RUF6L3lpYmdJOS8rcGU4VkxuRGgyWmR3RmlVYUpxRmx6dWZPUVVXaGhYOFNrPSIsIm5vbmNlIjoicFVKTStvRFF4R25CTXdITCIsImNpcGhlcnRleHQiOiIvRXZSc2FMdS9OM0JnUDZLbFk0WTc5ZmVDZlNnRlpZVlVkOXIyQXNyUnFQckxLN0dlUVpWMUdpREUyTURWcXZmIn0="
        let proof = try ClickCryptoV2.unwrapEpochKey(
            metadata: .init(chatId: "approval:11111111-1111-4111-8111-111111111111", epoch: 1,
                            senderDeviceId: "click-device-approval", recipientDeviceId: "phone-dev"),
            recipientPrivateKey: privateKey,
            envelope: envelope
        )
        #expect(proof == Data((1...32).map { UInt8($0) }))
        // Bound to the request and the approving device: any other metadata fails.
        #expect(throws: (any Error).self) {
            try ClickCryptoV2.unwrapEpochKey(
                metadata: .init(chatId: "approval:11111111-1111-4111-8111-111111111111", epoch: 1,
                                senderDeviceId: "click-device-approval", recipientDeviceId: "other-dev"),
                recipientPrivateKey: privateKey,
                envelope: envelope
            )
        }
    }
}
