import AVFoundation
import Foundation

/// The one place the app configures `AVAudioSession`.
///
/// `setCategory` / `setActive` block while the media server reconfigures routes (the system logs
/// "can lead to UI unresponsiveness" when they run on the main thread), so every call runs on a
/// private serial queue and callers `await` completion before starting a player or recorder.
/// Deactivation only happens when this controller activated the session, so closing a chat that
/// never played audio costs nothing.
final class AudioSessionController: @unchecked Sendable {
    static let shared = AudioSessionController()

    struct Configuration: Equatable, Sendable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions

        static let playback = Configuration(category: .playback, mode: .spokenAudio, options: [])
        static let voiceRecording = Configuration(category: .playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        /// Measurement mode disables voice processing that would filter near-ultrasonic tones.
        static let measurement = Configuration(category: .playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
    }

    private let queue = DispatchQueue(label: "click.audio-session", qos: .userInitiated)
    /// Touched only on `queue`.
    private var active: Configuration?

    private init() {}

    /// Configures and activates the session off the main thread.
    func activate(_ configuration: Configuration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if self.active != configuration {
                        try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
                    }
                    try session.setActive(true)
                    self.active = configuration
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Releases the session to other apps' audio; a no-op when this controller never activated it.
    func deactivate() {
        queue.async {
            guard self.active != nil else { return }
            self.active = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Awaitable variant for flows that must finish releasing before continuing.
    func deactivateAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.active != nil {
                    self.active = nil
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
                continuation.resume()
            }
        }
    }
}
