import Testing
import Foundation
@testable import Click

@Suite("Tap to Connect codec")
struct ProximityCodecTests {
    /// Mixes the synthesized handshake into a quiet, noisy capture at a mic-like level.
    private func capture(_ tokens: [String], gain: Double = 0.03, leadMs: Int = 237, noise: Double = 0.002) -> [Int16] {
        var generator = SeededGenerator(seed: 42)
        var samples = [Double](repeating: 0, count: ProximityCodec.sampleRate * 5)
        var cursor = leadMs * ProximityCodec.sampleRate / 1000
        for token in tokens {
            let pcm = ProximityCodec.handshakePCM(token: token)
            for (index, value) in pcm.enumerated() where cursor + index < samples.count {
                samples[cursor + index] += Double(value) / 32768 * gain
            }
            cursor += pcm.count + 13_000
        }
        return samples.map { value in
            let noisy = value + Double.random(in: -noise...noise, using: &generator)
            return Int16(max(min(noisy * 32767, 32767), -32768))
        }
    }

    @Test("Normalizes tokens like KMP normalizeHandshakeToken")
    func normalize() {
        #expect(ProximityCodec.normalize("7") == "0007")
        #expect(ProximityCodec.normalize("12-34") == "1234")
        #expect(ProximityCodec.normalize("12345678") == "5678")
        #expect(ProximityCodec.normalize("abc") == "0000")
        #expect(ProximityCodec.parseGattPayload(Data("0042".utf8)) == "0042")
        #expect(ProximityCodec.parseGattPayload(Data()) == nil)
    }

    @Test("Synthesized audio uses the 18.5 kHz production carrier and KMP timing")
    func synthesis() {
        let pcm = ProximityCodec.handshakePCM(token: "1234")
        // 140 ms chirp + 22 ms gap + 4 × (55 + 22) ms at 44.1 kHz.
        #expect(pcm.count == 6174 + 970 + 4 * (2426 + 970))
        #expect(ProximityCodec.carrierHz == 18_500)
        #expect(ProximityCodec.wav(pcm).count == 44 + pcm.count * 2)
    }

    @Test("Round-trips tokens, including repeated and zero digits, at microphone-like levels")
    func roundTrip() {
        for token in ["0000", "1134", "9876", "5050", "0071"] {
            #expect(ProximityCodec.decodeAllTokens(capture([token])) == [token], "token \(token)")
        }
    }

    @Test("Decodes several peers chirping in one listen window")
    func multiplePeers() {
        #expect(ProximityCodec.decodeAllTokens(capture(["4821", "0937"])) == ["0937", "4821"])
    }

    @Test("Noise alone yields no tokens")
    func noiseOnly() {
        #expect(ProximityCodec.decodeAllTokens(capture([], noise: 0.05)).isEmpty)
    }
}

/// Deterministic noise for reproducible codec tests.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("Tap to Connect server results")
struct ProximityResultTests {
    private func parse(_ json: String, status: Int = 200) throws -> ProximityBindResult {
        try ProximityRepository.result(data: Data(json.utf8), status: status)
    }

    @Test("A 200 with matches is a confirmed match; reconnects are not new connections")
    func matched() throws {
        let result = try parse(#"{"success":true,"connection_id":"c1","is_new_connection":false,"is_group":false,"encounter_logged":true,"matches":[{"id":"u2","first_name":"Theo","last_name":"Park","image":null}]}"#)
        guard case .matched(let match) = result else { Issue.record("expected match"); return }
        #expect(match.connectionID == "c1")
        #expect(!match.isNewConnection)
        #expect(match.peers.first?.name == "Theo Park")
    }

    @Test("First-time multi-peer taps require host selection before anything is created")
    func awaitingSelection() throws {
        let result = try parse(#"{"awaiting_selection":true,"pending_handshake_id":"p1","matches":[{"id":"a","name":"A"},{"id":"b","name":"B"}]}"#)
        #expect(result == .awaitingSelection(pendingID: "p1", candidates: [
            ProximityPeer(id: "a", name: "A", avatarURL: nil, connectionID: nil, isNewConnection: nil),
            ProximityPeer(id: "b", name: "B", avatarURL: nil, connectionID: nil, isNewConnection: nil)
        ]))
    }

    @Test("202 is pending (stored server-side), not success")
    func pending() throws {
        #expect(try parse(#"{"success":true,"status":"pending_match","pending_handshake_id":"p9","matches":[]}"#, status: 202) == .pending(pendingID: "p9"))
    }

    @Test("Ignored empty taps and error bodies never read as matches")
    func ignoredAndErrors() throws {
        #expect(try parse(#"{"success":false,"status":"ignored_empty_payload","matches":[]}"#) == .ignored)
        #expect(throws: APIError.self) { _ = try parse(#"{"error":"Invalid my_token"}"#) }
        #expect(ProximityRepository.pendingID(fromErrorBody: #"{"error":"connection_unavailable","pending_handshake_id":"p3"}"#) == "p3")
    }

    @Test("Bind body mirrors KMP ProximityHandshakePostBody")
    func body() {
        let evidence = ProximityEvidence(myToken: "0042", heardTokens: ["1111"], detectedDevices: ["2222", "1111"],
                                         latitude: nil, longitude: nil, simulatorMock: false)
        let body = evidence.body
        #expect(body["my_token"] as? String == "0042")
        #expect(body["tokens"] as? [String] == ["1111", "2222"])
        #expect(body["latitude"] == nil)
        #expect(body["simulator_mock"] == nil)
    }
}

@Suite("Cross-platform ultrasonic tokens")
struct CrossPlatformTokenTests {
    @Test("Generated tokens never repeat adjacent digits or start with 0")
    func generatedTokensAreSafe() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let token = ProximityCodec.randomToken(using: &generator)
            #expect(ProximityCodec.isCrossPlatformSafe(token), "unsafe token \(token)")
        }
    }

    @Test("Unsafe tokens are recognized")
    func unsafeTokens() {
        #expect(!ProximityCodec.isCrossPlatformSafe("7700"))
        #expect(!ProximityCodec.isCrossPlatformSafe("0123"))
        #expect(!ProximityCodec.isCrossPlatformSafe("1223"))
        #expect(ProximityCodec.isCrossPlatformSafe("1212"))
    }
}

@Suite("QR redeem messages")
struct QRRedeemMessageTests {
    @Test("Server QR error codes map to clear copy")
    func mapsCodes() {
        let expired = APIError.validation(code: "400", message: #"{"error":"expired"}"#)
        #expect(QRRedeemMessages.message(for: expired).contains("expired"))
        let used = APIError.validation(code: "400", message: #"{"error":"already_used"}"#)
        #expect(QRRedeemMessages.message(for: used).contains("already used"))
        #expect(QRRedeemMessages.message(for: APIError.forbidden).contains("same place"))
        #expect(QRRedeemMessages.message(for: APIError.validation(code: "400", message: "garbage")) == "Couldn't redeem that code. Try again.")
    }
}
