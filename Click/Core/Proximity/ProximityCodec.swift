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

    /// A 4-digit token the KMP (Android) decoder can hear reliably: its Goertzel pass merges
    /// repeated adjacent digits (\"7700\" is heard as \"70\") and digit 0 shares the 18.5 kHz
    /// carrier, so a leading 0 merges with the chirp. iOS therefore never emits either. This
    /// still leaves 9·9·9·9 = 6 561 tokens; the server matches on overlapping evidence, not the
    /// token alone.
    static func randomToken<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var digits: [Int] = [Int.random(in: 1...9, using: &generator)]
        while digits.count < 4 {
            var next = Int.random(in: 0...8, using: &generator)
            if next >= digits[digits.count - 1] { next += 1 }
            digits.append(next)
        }
        return digits.map(String.init).joined()
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomToken(using: &generator)
    }

    /// True when the KMP decoder can hear `token` unambiguously.
    nonisolated static func isCrossPlatformSafe(_ token: String) -> Bool {
        let digits = Array(token)
        guard digits.count == 4, digits.allSatisfy(\.isNumber), digits.first != "0" else { return false }
        return zip(digits, digits.dropFirst()).allSatisfy { $0 != $1 }
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
        decodeWithMetrics(samples).tokens
    }

    /// The tokens plus the signal and decoder statistics the decoder already computes (no
    /// audio): chirp power and dominance, the weakest digit margin, a noise floor from
    /// chirp-free frames, and how many chirp-length runs were tried or failed.
    static func decodeWithMetrics(_ samples: [Int16]) -> UltrasonicDecode {
        let captureRMS = rms(samples)
        guard samples.count >= sampleRate / 4 else {
            return UltrasonicDecode(detections: [], samplesAnalyzed: samples.count, captureRMS: captureRMS,
                                    noiseFloorPower: nil, attempts: 0, failedAttempts: 0)
        }
        let hop = sampleRate / 100 // 10 ms analysis frames
        var frames: [CarrierFrame] = []
        var frameStart = 0
        while frameStart + hop <= samples.count {
            frames.append(carrierFrame(samples, offset: frameStart, length: hop))
            frameStart += hop
        }
        let quiet = frames.filter { !$0.isDominant }.map(\.power).sorted()
        let noiseFloor = quiet.isEmpty ? nil : quiet[quiet.count / 2]

        var detections: [UltrasonicDetection] = []
        var attempts = 0
        var failed = 0
        var index = 0
        while index < frames.count {
            guard frames[index].isDominant else { index += 1; continue }
            var end = index
            while end < frames.count, frames[end].isDominant { end += 1 }
            // A digit-0 tone is 55 ms; only the 140 ms chirp produces a run this long.
            if end - index >= 11 {
                attempts += 1
                // The first carrier frame may be partial; the run end is the chirp's sharp edge.
                let chirpEnd = end * hop
                let chirpStart = max(0, chirpEnd - sampleCount(ms: chirpMs))
                if let digits = readDigits(samples, chirpStart: chirpStart) {
                    if let seen = detections.firstIndex(where: { $0.token == digits.token }) {
                        detections[seen].detections += 1
                    } else {
                        let run = frames[index..<end]
                        detections.append(UltrasonicDetection(
                            token: digits.token,
                            chirpStartSample: chirpStart,
                            chirpFrames: end - index,
                            carrierPower: run.map(\.power).reduce(0, +) / Double(run.count),
                            carrierDominance: run.map(\.dominance).reduce(0, +) / Double(run.count),
                            signalRMS: rms(Array(samples[chirpStart..<min(chirpEnd, samples.count)])),
                            peakToSecondPeakRatio: digits.weakestMargin,
                            digitPower: digits.meanPower,
                            detections: 1
                        ))
                    }
                } else {
                    failed += 1
                }
            }
            index = end
        }
        return UltrasonicDecode(detections: detections, samplesAnalyzed: samples.count, captureRMS: captureRMS,
                                noiseFloorPower: noiseFloor, attempts: attempts, failedAttempts: failed)
    }

    private struct CarrierFrame {
        let power: Double
        /// Carrier ÷ strongest off-carrier probe (capped when the probes are silent).
        let dominance: Double
        let isDominant: Bool
    }

    private static func readDigits(_ samples: [Int16], chirpStart: Int) -> (token: String, weakestMargin: Double, meanPower: Double)? {
        let slot = sampleCount(ms: toneMs + gapMs)
        let firstDigit = chirpStart + sampleCount(ms: chirpMs + gapMs)
        // Chirp-edge timing is known to within one 10 ms frame; a 30 ms window starting 12 ms
        // into each 55 ms tone tolerates -12…+13 ms of error.
        let margin = sampleCount(ms: 12)
        let window = sampleCount(ms: 30)
        var digits = ""
        var weakest = Double.greatestFiniteMagnitude
        var totalPower = 0.0
        for position in 0..<4 {
            let start = firstDigit + position * slot + margin
            guard start + window <= samples.count else { return nil }
            let powers = (0...9).map { goertzel(samples, offset: start, length: window, frequency: digitFrequency($0)) }
            let ranked = powers.enumerated().sorted { $0.element > $1.element }
            guard ranked[0].element > minimumPower, ranked[0].element > ranked[1].element * 4 else { return nil }
            digits += String(ranked[0].offset)
            weakest = min(weakest, ranked[1].element > 0 ? ranked[0].element / ranked[1].element : maximumRatio)
            totalPower += ranked[0].element
        }
        return (digits, min(weakest, maximumRatio), totalPower / 4)
    }

    /// The carrier dominates its neighbourhood (so broadband noise or speech does not count).
    private static func carrierFrame(_ samples: [Int16], offset: Int, length: Int) -> CarrierFrame {
        let carrier = goertzel(samples, offset: offset, length: length, frequency: carrierHz)
        let neighbour = [carrierHz - 400, carrierHz + digitStepHz * 2, carrierHz + digitStepHz * 5, 12_000]
            .map { goertzel(samples, offset: offset, length: length, frequency: $0) }
            .max() ?? 0
        return CarrierFrame(
            power: carrier,
            dominance: neighbour > 0 ? min(carrier / neighbour, maximumRatio) : (carrier > 0 ? maximumRatio : 0),
            isDominant: carrier > minimumPower && carrier > neighbour * 6
        )
    }

    /// Ratios over a silent bin are capped rather than reported as infinite.
    private static let maximumRatio = 1e6

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
