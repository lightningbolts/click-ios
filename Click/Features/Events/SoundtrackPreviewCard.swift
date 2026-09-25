import AVFoundation
import SwiftUI

/// Streams one 30 s iTunes preview at a time (starting another stops the previous one).
@Observable
@MainActor
final class SoundtrackPreviewPlayer {
    static let shared = SoundtrackPreviewPlayer()

    private(set) var activeURL: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 30

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func isActive(_ url: String) -> Bool { activeURL == url }

    func toggle(_ url: String) async {
        if activeURL == url, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                try? await AudioSessionController.shared.activate(.playback)
                if position >= duration - 0.2 { await player.seek(to: .zero) }
                player.play()
                isPlaying = true
            }
            return
        }
        guard SoundtrackResolver.isTrustedPreview(url), let remote = URL(string: url) else { return }
        stop()
        AudioPlaybackService.shared.stop()   // one audio source at a time (voice notes too)
        activeURL = url
        isLoading = true
        position = 0
        try? await AudioSessionController.shared.activate(.playback)
        let item = AVPlayerItem(url: remote)
        let next = AVPlayer(playerItem: item)
        player = next
        timeObserver = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                    self.isLoading = false
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.position = self?.duration ?? 0
            }
        }
        next.play()
        isPlaying = true
    }

    /// Scrubbing: `fraction` of the preview (0…1).
    func seek(_ url: String, to fraction: Double) async {
        guard activeURL == url, let player else { return }
        let target = max(0, min(1, fraction)) * duration
        position = target
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        let wasActive = player != nil
        player?.pause()
        player = nil
        activeURL = nil
        isPlaying = false
        isLoading = false
        position = 0
        duration = 30
        if wasActive { AudioSessionController.shared.deactivate() }
    }
}

/// Album art, track and artist, with a playable preview and a scrubbable slider (KMP
/// `CommunitySoundtrackBeaconDetail` preview row). Used in the beacon detail and the drop form.
struct SoundtrackPreviewCard: View {
    let trackName: String
    let artistName: String?
    let artworkURL: String?
    let previewURL: String?
    var seed = "soundtrack"

    @State private var player = SoundtrackPreviewPlayer.shared
    @State private var dragFraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                EventVisual(seed: seed, imageURL: artworkURL, symbol: artworkURL == nil ? "music.note" : nil, cornerRadius: 10)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trackName)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(2)
                    if let artistName, !artistName.isEmpty {
                        Text(artistName)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if let previewURL {
                previewRow(previewURL)
            } else {
                Text("No preview available for this track.")
                    .font(ClickTypography.caption)
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .padding(14)
        .background(ClickColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func previewRow(_ url: String) -> some View {
        let active = player.isActive(url)
        let fraction = dragFraction ?? (active && player.duration > 0 ? player.position / player.duration : 0)
        return HStack(spacing: 12) {
            Button {
                ClickHaptics.selection()
                Task { await player.toggle(url) }
            } label: {
                ZStack {
                    Circle().fill(ClickColors.primaryActionFill)
                    if active, player.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active && player.isPlaying ? "Pause preview" : "Play preview")

            VStack(spacing: 2) {
                Slider(value: Binding(
                    get: { fraction },
                    set: { dragFraction = $0 }
                ), in: 0...1) { editing in
                    guard !editing, let target = dragFraction else { return }
                    Task {
                        if !player.isActive(url) { await player.toggle(url) }
                        await player.seek(url, to: target)
                        dragFraction = nil
                    }
                }
                .tint(ClickColors.accentForeground)
                HStack {
                    Text(Self.clock(fraction * (active ? player.duration : 30)))
                    Spacer()
                    Text(Self.clock(active ? player.duration : 30))
                }
                .font(ClickTypography.caption.monospacedDigit())
                .foregroundStyle(ClickColors.textTertiary)
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The soundtrack section of a beacon's detail. Beacons the server couldn't enrich (its
/// iTunes lookup can miss) are resolved on this device from the song link, so every
/// soundtrack shows art and a playable preview.
struct SoundtrackBeaconSection: View {
    let beacon: MapBeacon
    /// Hands resolved artwork to the hero banner.
    var onArtwork: (String) -> Void = { _ in }
    @State private var resolved: SoundtrackMatch?

    var body: some View {
        SoundtrackPreviewCard(
            trackName: resolved?.trackName ?? beacon.trackName ?? beacon.title,
            artistName: resolved?.artistName ?? beacon.artistName,
            artworkURL: resolved?.artworkURL ?? beacon.albumArtURL,
            previewURL: resolved?.previewURL ?? beacon.previewURL,
            seed: beacon.id
        )
        .task(id: beacon.id) {
            guard beacon.previewURL == nil || beacon.albumArtURL == nil, let link = beacon.musicURL else { return }
            resolved = await SoundtrackResolver.resolve(link)
            if let art = resolved?.artworkURL { onArtwork(art) }
        }
    }
}
