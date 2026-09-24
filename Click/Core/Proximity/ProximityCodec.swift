import Foundation

/// Wire-compatible Tap to Connect identifiers and the ultrasonic token codec.
///
/// Ported from KMP `ProximityBleCodec.kt` / `UltrasonicTokenCodec.kt` so native iOS, Android,
/// and the KMP iOS build exchange the same evidence. Tap to Connect is BLE + ~18.5 kHz audio +
/// GPS — not NFC (spec §110). The server (`POST /api/connections/proximity`) is the only verifier.
enum ProximityCodec {
    /// Advertised alone so the packet fits the 31-byte legacy advertisement.
    static let serviceUUID = "6f1c8c2a-1111-4000-8000-00cafe000001"
    /// Readable GATT characteristic carrying the 4-digit handshake token as UTF-8.
    static let tokenCharacteristicUUID = "6f1c8c2a-2222-4000-8000-00cafe000001"

    /// The only production carrier. Audible development carriers must never ship.
    static let carrierHz = 18_500.0
    static let sampleRate = 44_100
    private static let digitStepHz = 120.0
    private static let toneMs = 55
    private static let gapMs = 22
    private static let chirpMs = 140

    /// Simulator stand-in evidence understood by the server only when its mock flag is enabled
    /// (never in production).
    static let simulatorMyToken = "1234"
    static let simulatorHeardTokens = ["5678"]

    /// Last four digits, zero-padded (`normalizeHandshakeToken`).
    static func normalize(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber).suffix(4)
        let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
        return padded.count == 4 ? padded : nil
    }

    static func randomToken() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    static func gattPayload(_ token: String) -> Data {
        Data(token.utf8)
    }

    static func parseGattPayload(_ data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalize(trimmed)
    }

    // MARK: - Ultrasonic synthesis

    /// 140 ms carrier chirp, then one 55 ms tone per digit (carrier + digit × 120 Hz), 22 ms gaps.
    static func handshakePCM(token: String) -> [Int16] {
        guard let normalized = normalize(token) else { return [] }
        var out: [Int16] = []
        out.reserveCapacity(20_000)
        appendSine(&out, frequency: carrierHz, durationMs: chirpMs, amplitude: 0.95)
        appendSilence(&out, durationMs: gapMs)
        for character in normalized {
            appendSine(&out, frequency: digitFrequency(character.wholeNumberValue ?? 0), durationMs: toneMs, amplitude: 0.6)
            appendSilence(&out, durationMs: gapMs)
        }
        return out
    }

    /// Mono 16-bit PCM wrapped in a canonical 44-byte WAV header for `AVAudioPlayer`.
    static func wav(_ pcm: [Int16]) -> Data {
        var data = Data(capacity: 44 + pcm.count * 2)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append32(16); append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2))
        append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(dataSize)
        pcm.withUnsafeBufferPointer { buffer in
            for sample in buffer { append16(UInt16(bitPattern: sample)) }
        }
        return data
    }

    // MARK: - Decoding

    // The emitted audio above is the wire contract. The KMP decoder's filter never carried its
    // Goertzel state correctly and merged repeated adjacent digits (e.g. "1134"), so native uses
    // a chirp-synchronized decoder instead: find each ≥110 ms carrier run, then read the four
    // digit slots at their fixed offsets (chirp 140 ms + 22 ms gap, then 55 ms tone + 22 ms gap).
    // Any peer that emits this audio (Android, KMP iOS, native) is decodable.

    /// Every distinct 4-digit token in a capture (several peers may chirp in one window).
    static func decodeAllTokens(_ samples: [Int16]) -> [String] {
        guard samples.count >= sampleRate / 4 else { return [] }
        let hop = sampleRate / 100 // 10 ms analysis frames
        var carrierFrames: [Bool] = []
        var frameStart = 0
        while frameStart + hop <= samples.count {
            carrierFrames.append(isCarrierDominant(samples, offset: frameStart, length: hop))
            frameStart += hop
        }

        var tokens = Set<String>()
        var index = 0
        while index < carrierFrames.count {
            guard carrierFrames[index] else { index += 1; continue }
            var end = index
            while end < carrierFrames.count, carrierFrames[end] { end += 1 }
            // A digit-0 tone is 55 ms; only the 140 ms chirp produces a run this long.
            if end - index >= 11 {
                // The first carrier frame may be partial; the run end is the chirp's sharp edge.
                let chirpEnd = end * hop
                let chirpStart = max(0, chirpEnd - sampleCount(ms: chirpMs))
                if let token = readDigits(samples, chirpStart: chirpStart) {
                    tokens.insert(token)
                }
            }
            index = end
        }
        return tokens.sorted()
    }

    private static func readDigits(_ samples: [Int16], chirpStart: Int) -> String? {
        let slot = sampleCount(ms: toneMs + gapMs)
        let firstDigit = chirpStart + sampleCount(ms: chirpMs + gapMs)
        // Chirp-edge timing is known to within one 10 ms frame; a 30 ms window starting 12 ms
        // into each 55 ms tone tolerates -12…+13 ms of error.
        let margin = sampleCount(ms: 12)
        let window = sampleCount(ms: 30)
        var digits = ""
        for position in 0..<4 {
            let start = firstDigit + position * slot + margin
            guard start + window <= samples.count else { return nil }
            let powers = (0...9).map { goertzel(samples, offset: start, length: window, frequency: digitFrequency($0)) }
            let ranked = powers.enumerated().sorted { $0.element > $1.element }
            guard ranked[0].element > minimumPower, ranked[0].element > ranked[1].element * 4 else { return nil }
            digits += String(ranked[0].offset)
        }
        return digits
    }

    /// The carrier dominates its neighbourhood (so broadband noise or speech does not count).
    private static func isCarrierDominant(_ samples: [Int16], offset: Int, length: Int) -> Bool {
        let carrier = goertzel(samples, offset: offset, length: length, frequency: carrierHz)
        guard carrier > minimumPower else { return false }
        let neighbours = [carrierHz - 400, carrierHz + digitStepHz * 2, carrierHz + digitStepHz * 5, 12_000]
            .map { goertzel(samples, offset: offset, length: length, frequency: $0) }
        return carrier > (neighbours.max() ?? 0) * 6
    }

    /// Normalized power floor (≈ amplitude 0.0006): quiet enough for a phone a few centimetres
    /// away; spectral dominance checks, not loudness, reject noise.
    private static let minimumPower = 1e-7

    private static func sampleCount(ms: Int) -> Int {
        Int((Double(sampleRate * ms) / 1000).rounded())
    }

    static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { partial, sample in
            let normalized = Double(sample) / 32768
            return partial + normalized * normalized
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    // MARK: - Private

    private static func digitFrequency(_ digit: Int) -> Double {
        carrierHz + Double(min(max(digit, 0), 9)) * digitStepHz
    }

    /// Power of one frequency over `samples[offset..<offset+length]` (standard Goertzel).
    private static func goertzel(_ samples: [Int16], offset: Int, length: Int, frequency: Double) -> Double {
        guard length >= 8 else { return 0 }
        let omega = 2 * Double.pi * frequency / Double(sampleRate)
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforePrevious = 0.0
        for i in 0..<length {
            let current = Double(samples[offset + i]) / 32768 + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return power / Double(length * length)
    }

    private static func appendSine(_ out: inout [Int16], frequency: Double, durationMs: Int, amplitude: Double) {
        let count = max(Int((Double(sampleRate * durationMs) / 1000).rounded()), 1)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            let value = (amplitude * 32767 * sin(2 * Double.pi * frequency * t)).rounded()
            out.append(Int16(max(min(value, Double(Int16.max)), Double(Int16.min))))
        }
    }

    private static func appendSilence(_ out: inout [Int16], durationMs: Int) {
        let count = max(Int((Double(sampleRate * durationMs) / 1000).rounded()), 1)
        out.append(contentsOf: repeatElement(0, count: count))
    }
}
