import Foundation

// Raw per-tap radio and acoustic traces, stamped on the monotonic `SensorClock`. Only Click
// peers that served a token are kept: unrelated Bluetooth devices never get an identifier,
// and no audio ever leaves `UltrasonicService` — only signal and decoder statistics.

/// One Click peripheral seen during a tap's BLE exchange.
struct BluetoothPeerTrace: Equatable, Sendable {
    /// Bounded RSSI series: duplicate advertisements plus one connected `readRSSI`.
    static let maximumRSSISamples = 32

    let firstSeen: TimeInterval
    var rssiSamples: [Int] = []
    var txPower: Int?
    var connectable: Bool?
    var connectStarted: TimeInterval?
    var connected: TimeInterval?
    var servicesDiscovered: TimeInterval?
    var characteristicDiscovered: TimeInterval?
    var tokenRead: TimeInterval?
    var token: String?

    init(firstSeen: TimeInterval) {
        self.firstSeen = firstSeen
    }

    /// CoreBluetooth reports 127 when RSSI is unavailable; such values are not samples.
    mutating func record(rssi: Int) {
        guard rssi != 127, (-130...20).contains(rssi), rssiSamples.count < Self.maximumRSSISamples else { return }
        rssiSamples.append(rssi)
    }
}

/// The BLE side of one tap: when scanning started and every peer that served its token.
struct BluetoothTrace: Equatable, Sendable {
    var scanStarted: TimeInterval?
    var peers: [BluetoothPeerTrace] = []
}

/// Playback, recording and decoding timeline of one tap's ultrasonic exchange.
struct AcousticTrace: Equatable, Sendable {
    var playRequested: TimeInterval?
    var playStarted: TimeInterval?
    var playFinished: TimeInterval?
    var recordStarted: TimeInterval?
    var recordStopped: TimeInterval?
    var decodeStarted: TimeInterval?
    var decodeFinished: TimeInterval?
    /// Decoder statistics for peers only (this phone's own token is removed).
    var decode: UltrasonicDecode?
}

/// What the chirp-synchronized decoder measured for one detected token.
struct UltrasonicDetection: Equatable, Sendable {
    let token: String
    /// Offset of the chirp in the capture (samples from the recording start).
    let chirpStartSample: Int
    /// Consecutive 10 ms carrier-dominant frames (the chirp's length as heard).
    let chirpFrames: Int
    /// Mean normalized Goertzel power of the carrier over the chirp.
    let carrierPower: Double
    /// Mean ratio of carrier power to the strongest off-carrier probe.
    let carrierDominance: Double
    let signalRMS: Double
    /// Weakest of the four digit decisions: best ÷ second-best digit power.
    let peakToSecondPeakRatio: Double
    let digitPower: Double
    /// How many chirps in the window decoded to this token.
    var detections: Int
}

struct UltrasonicDecode: Equatable, Sendable {
    let detections: [UltrasonicDetection]
    let samplesAnalyzed: Int
    let captureRMS: Double
    /// Median carrier power of frames without a chirp; nil when every frame had one.
    let noiseFloorPower: Double?
    /// Chirp-length carrier runs examined, and how many failed to yield four digits.
    let attempts: Int
    let failedAttempts: Int

    var tokens: [String] { detections.map(\.token).sorted() }

    func excluding(_ token: String) -> UltrasonicDecode {
        UltrasonicDecode(
            detections: detections.filter { $0.token != token },
            samplesAnalyzed: samplesAnalyzed, captureRMS: captureRMS, noiseFloorPower: noiseFloorPower,
            attempts: attempts, failedAttempts: failedAttempts
        )
    }
}

// MARK: - Wire form (all `*_ms` timeline values are relative to the connection moment)

struct BluetoothObservation: Codable, Equatable, Sendable {
    var scanStartedMs: Int?
    var peers: [Peer]

    struct Peer: Codable, Equatable, Sendable {
        var token: String
        var rssiSamplesDbm: [Int]
        var rssiMinDbm: Int?
        var rssiMaxDbm: Int?
        var rssiMedianDbm: Double?
        var rssiStdDbm: Double?
        var txPowerDbm: Int?
        var connectable: Bool?
        /// Advertised TX power − median RSSI. Proximity evidence, never a distance.
        var pathLossDb: Double?
        var firstSeenMs: Int
        var connectStartedMs: Int?
        var connectedMs: Int?
        var servicesDiscoveredMs: Int?
        var characteristicDiscoveredMs: Int?
        var tokenReadMs: Int?
        var timeToDiscoveryMs: Int?
        var connectionLatencyMs: Int?
        var gattDiscoveryLatencyMs: Int?
        var gattReadLatencyMs: Int?
    }

    init?(_ trace: BluetoothTrace?, momentUptime: TimeInterval) {
        guard let trace else { return nil }
        let at = { (uptime: TimeInterval?) in uptime.map { SensorClock.milliseconds($0 - momentUptime) } }
        let span = { (from: TimeInterval?, to: TimeInterval?) -> Int? in
            guard let from, let to, to >= from else { return nil }
            return SensorClock.milliseconds(to - from)
        }
        scanStartedMs = at(trace.scanStarted)
        peers = trace.peers.compactMap { peer in
            guard let token = peer.token else { return nil }
            let sorted = peer.rssiSamples.sorted()
            let median = Self.median(sorted)
            return Peer(
                token: token,
                rssiSamplesDbm: peer.rssiSamples,
                rssiMinDbm: sorted.first,
                rssiMaxDbm: sorted.last,
                rssiMedianDbm: median,
                rssiStdDbm: sorted.isEmpty ? nil : LocationObservation.rounded(
                    MotionObservation.standardDeviation(sorted.map(Double.init)), places: 2
                ),
                txPowerDbm: peer.txPower,
                connectable: peer.connectable,
                pathLossDb: peer.txPower.flatMap { tx in median.map { Double(tx) - $0 } },
                firstSeenMs: SensorClock.milliseconds(peer.firstSeen - momentUptime),
                connectStartedMs: at(peer.connectStarted),
                connectedMs: at(peer.connected),
                servicesDiscoveredMs: at(peer.servicesDiscovered),
                characteristicDiscoveredMs: at(peer.characteristicDiscovered),
                tokenReadMs: at(peer.tokenRead),
                timeToDiscoveryMs: span(trace.scanStarted, peer.firstSeen),
                connectionLatencyMs: span(peer.connectStarted, peer.connected),
                gattDiscoveryLatencyMs: span(peer.connected, peer.characteristicDiscovered),
                gattReadLatencyMs: span(peer.characteristicDiscovered, peer.tokenRead)
            )
        }
    }

    static func median(_ sorted: [Int]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? Double(sorted[middle - 1] + sorted[middle]) / 2
            : Double(sorted[middle])
    }
}

struct AcousticObservation: Codable, Equatable, Sendable {
    var chirpPlayRequestedMs: Int?
    var playbackStartedMs: Int?
    var playbackFinishedMs: Int?
    var listenStartedMs: Int?
    var listenFinishedMs: Int?
    var decodeStartedMs: Int?
    var decodeFinishedMs: Int?
    var decodeDurationMs: Int?
    var samplesAnalyzed: Int?
    var captureRms: Double?
    var noiseFloor: Double?
    var decodeAttemptCount: Int?
    var failedDecodeCount: Int?
    var peers: [Peer]

    struct Peer: Codable, Equatable, Sendable {
        var token: String
        /// When this peer's chirp began, relative to the connection moment.
        var firstDetectedMs: Int?
        var detections: Int
        var chirpMs: Int
        var chirpPeakPower: Double?
        var carrierDominance: Double?
        var signalRms: Double?
        var signalToNoiseRatioDb: Double?
        var peakToSecondPeakRatio: Double?
        var digitPower: Double?
    }

    init?(_ trace: AcousticTrace?, momentUptime: TimeInterval) {
        guard let trace else { return nil }
        let at = { (uptime: TimeInterval?) in uptime.map { SensorClock.milliseconds($0 - momentUptime) } }
        let decode = trace.decode
        chirpPlayRequestedMs = at(trace.playRequested)
        playbackStartedMs = at(trace.playStarted)
        playbackFinishedMs = at(trace.playFinished)
        listenStartedMs = at(trace.recordStarted)
        listenFinishedMs = at(trace.recordStopped)
        decodeStartedMs = at(trace.decodeStarted)
        decodeFinishedMs = at(trace.decodeFinished)
        if let start = trace.decodeStarted, let end = trace.decodeFinished, end >= start {
            decodeDurationMs = SensorClock.milliseconds(end - start)
        }
        samplesAnalyzed = decode?.samplesAnalyzed
        captureRms = decode.flatMap { Self.metric($0.captureRMS, places: 6) }
        noiseFloor = decode?.noiseFloorPower.flatMap { Self.metric($0, places: 12) }
        decodeAttemptCount = decode?.attempts
        failedDecodeCount = decode?.failedAttempts
        peers = (decode?.detections ?? []).map { detection in
            let offset = Double(detection.chirpStartSample) / Double(ProximityCodec.sampleRate)
            let snr = decode?.noiseFloorPower.flatMap { floor in
                floor > 0 && detection.carrierPower > 0 ? 10 * log10(detection.carrierPower / floor) : nil
            }
            return Peer(
                token: detection.token,
                firstDetectedMs: trace.recordStarted.map { SensorClock.milliseconds($0 + offset - momentUptime) },
                detections: detection.detections,
                chirpMs: detection.chirpFrames * 10,
                chirpPeakPower: Self.metric(detection.carrierPower, places: 12),
                carrierDominance: Self.metric(detection.carrierDominance, places: 2),
                signalRms: Self.metric(detection.signalRMS, places: 6),
                signalToNoiseRatioDb: snr.flatMap { Self.metric($0, places: 2) },
                peakToSecondPeakRatio: Self.metric(detection.peakToSecondPeakRatio, places: 2),
                digitPower: Self.metric(detection.digitPower, places: 12)
            )
        }
    }

    /// Non-finite decoder values (e.g. a ratio over an empty bin) are dropped, not invented.
    static func metric(_ value: Double, places: Int) -> Double? {
        guard value.isFinite else { return nil }
        let rounded = LocationObservation.rounded(value, places: places)
        return rounded.isFinite ? rounded : nil
    }
}
