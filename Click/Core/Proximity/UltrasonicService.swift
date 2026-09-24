import AVFoundation
import Foundation

/// The ~18.5 kHz sound factor of Tap to Connect (spec §23.6).
///
/// Plays this tap's token tones and records one bounded listen window, then decodes off the
/// main actor. The microphone is never left running: recording stops after the window, the
/// temporary capture file is deleted, and the audio session is released for other audio
/// (voice notes, media) with `notifyOthersOnDeactivation`.
@MainActor
final class UltrasonicService {
    enum Failure: Error {
        case microphoneDenied
        case sessionUnavailable
    }

    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?

    func activateSession() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw Failure.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        do {
            // Measurement mode disables voice processing that would filter near-ultrasonic tones.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
        } catch {
            throw Failure.sessionUnavailable
        }
    }

    /// Plays the chirp + digit tones once and returns when playback has finished.
    func play(token: String) async {
        let pcm = ProximityCodec.handshakePCM(token: token)
        guard !pcm.isEmpty, let player = try? AVAudioPlayer(data: ProximityCodec.wav(pcm)) else { return }
        self.player = player
        player.volume = 1
        player.prepareToPlay()
        player.play()
        let durationMs = pcm.count * 1000 / ProximityCodec.sampleRate + 120
        try? await Task.sleep(for: .milliseconds(durationMs))
        player.stop()
        self.player = nil
    }

    /// Records mono 44.1 kHz PCM for `duration` after `delay` and returns tokens heard, excluding
    /// `ownToken`. Decoding runs off the main actor.
    func listen(after delay: Duration, for duration: Duration, excluding ownToken: String) async -> [String] {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return [] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("click-tap-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(ProximityCodec.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.prepareToRecord() else {
            return []
        }
        self.recorder = recorder
        recorder.record()
        try? await Task.sleep(for: duration)
        recorder.stop()
        self.recorder = nil

        return await Task.detached(priority: .userInitiated) {
            guard let samples = Self.readSamples(url), ProximityCodec.rms(samples) >= 0.0005 else { return [] }
            return ProximityCodec.decodeAllTokens(samples).filter { $0 != ownToken }
        }.value
    }

    /// Stops any playback/recording and releases the audio session to other audio.
    func stop() {
        player?.stop()
        player = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private nonisolated static func readSamples(_ url: URL) -> [Int16]? {
        guard
            let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channel = buffer.int16ChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
