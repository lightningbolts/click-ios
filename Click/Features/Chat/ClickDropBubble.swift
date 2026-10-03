import SwiftUI
import UIKit

/// What a Click Drop bubble needs from its conversation. The closures are read inside the bubble's
/// body, so the bubble re-renders when the conversation's develop state changes.
public struct ClickDropControls {
    let state: () -> ClickDropDevelopState
    let isDeveloping: () -> Bool
    /// Developed on this screen just now: play the develop animation once.
    let isFreshlyDeveloped: () -> Bool
    let develop: () async -> Void
    let didShowDevelop: () -> Void
    /// The developed photo (a gated drop's original, or a legacy drop's own media).
    let loadDeveloped: () async throws -> URL
}

/// A Click Drop photo (spec §2): pixelated with a countdown while pending, quietly waiting for a
/// tap when ready, and the photo once developed — resolving from pixels with a light haptic.
struct ClickDropImageView: View {
    let message: ChatMessageItem
    /// The message's own media: a gated drop's pixelated preview, or a legacy drop's photo.
    let loadPreview: () async throws -> URL
    let controls: ClickDropControls
    let onOpen: (URL) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pixelated: UIImage?
    @State private var developed: (image: UIImage, url: URL)?
    /// This bubble plays the develop (developed on this screen just now).
    @State private var playsDevelop = false
    @State private var failed = false
    @State private var historyLocked = false
    /// Bumped at reveal time so a pending drop becomes ready on screen.
    @State private var tick = 0

    private var placeholderSize: CGSize {
        MediaAspectCache.displaySize(aspect: MediaAspectCache.aspect(for: message) ?? 1.2)
    }

    var body: some View {
        let _ = tick
        let state = controls.state()
        Group {
            if historyLocked {
                LockedMediaBox(size: placeholderSize)
            } else if failed {
                retryBox
            } else if state == .developed, let developed {
                Button { onOpen(developed.url) } label: {
                    Image(uiImage: developed.image)
                        .resizable()
                        .aspectRatio(developed.image.size, contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 320)
                        .clickDropDevelop(true, plays: playsDevelop)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Click Drop photo. Opens full screen.")
            } else if let pixelated {
                lockedImage(pixelated, state: state)
            } else {
                MediaLoadingPlaceholder(width: placeholderSize.width, height: placeholderSize.height)
            }
        }
        .background(ClickColors.fillSubtle)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
        .task(id: message.stableID) { await loadPixelated() }
        .task(id: state == .developed) {
            guard state == .developed, developed == nil else { return }
            await loadDeveloped()
        }
    }

    private func lockedImage(_ image: UIImage, state: ClickDropDevelopState) -> some View {
        let isReady = state == .ready
        return Button {
            guard isReady, !controls.isDeveloping() else { return }
            Task { await controls.develop() }
        } label: {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(image.size, contentMode: .fit)
                .frame(maxWidth: 240, maxHeight: 320)
                .shimmering(state == .developed || controls.isDeveloping())
                .overlay { stateLabel(state) }
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .accessibilityLabel(accessibilityLabel(state))
        .accessibilityHint(isReady ? "Double tap to develop." : "")
        .task(id: pendingRevealAt(state)) {
            guard let revealAt = pendingRevealAt(state) else { return }
            try? await Task.sleep(for: .seconds(max(0, revealAt.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
            tick += 1
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: ClickDropDevelopState) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .pending(let revealAt):
                Image(systemName: "hourglass")
                Text("Click Drop · develops \(revealAt.formatted(.relative(presentation: .named)))")
            case .ready:
                Image(systemName: "sparkles")
                Text(controls.isDeveloping() ? "Developing…" : "Tap to develop")
            case .developed:
                Image(systemName: "sparkles")
                Text("Developing…")
            }
        }
        .font(ClickTypography.metadataEmphasized)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private func pendingRevealAt(_ state: ClickDropDevelopState) -> Date? {
        if case .pending(let revealAt) = state, revealAt != .distantFuture { return revealAt }
        return nil
    }

    private func accessibilityLabel(_ state: ClickDropDevelopState) -> String {
        switch state {
        case .pending(let revealAt): "Click Drop photo, develops \(revealAt.formatted(.relative(presentation: .named)))"
        case .ready: "Click Drop photo, ready to develop"
        case .developed: "Click Drop photo, developing"
        }
    }

    private var retryBox: some View {
        Button {
            failed = false
            Task {
                if pixelated == nil { await loadPixelated() }
                if controls.state() == .developed { await loadDeveloped() }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.exclamationmark")
                Text("Couldn't load photo. Tap to retry.").font(ClickTypography.metadata)
            }
            .foregroundStyle(ClickColors.textSecondary)
            .frame(width: placeholderSize.width, height: placeholderSize.height)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private nonisolated static func thumbnail(_ url: URL) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let scale = min(1, 720 / max(image.size.width, image.size.height))
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }

    private func loadPixelated() async {
        guard pixelated == nil else { return }
        if let cached = DecodedMediaCache.entry(for: message)?.pixelated {
            pixelated = cached
            return
        }
        do {
            let url = try await loadPreview()
            let decoded = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage)? in
                guard let image = Self.thumbnail(url), let blocks = ClickDropPixelation.pixelated(image) else { return nil }
                return (image, blocks)
            }.value
            guard let decoded else { throw ChatRepositoryError.mediaUnavailable }
            MediaAspectCache.remember(decoded.0.size, for: message)
            DecodedMediaCache.insert(decoded.0, pixelated: decoded.1, url: url, for: message)
            withAnimation(ClickMotion.subtleFade) { pixelated = decoded.1 }
        } catch ChatRepositoryError.historyKeyUnavailable {
            historyLocked = true
        } catch {
            if !error.isCancellation { failed = true }
        }
    }

    private func loadDeveloped() async {
        let key = "\(message.id)#developed"
        if let cached = DecodedMediaCache.entry(key) {
            developed = (cached.image, cached.url)
            return
        }
        do {
            let url = try await controls.loadDeveloped()
            let image = await Task.detached(priority: .userInitiated) { Self.thumbnail(url) }.value
            guard let image else { throw ChatRepositoryError.mediaUnavailable }
            DecodedMediaCache.insert(image, url: url, for: key)
            await present(image, url: url)
        } catch ChatRepositoryError.historyKeyUnavailable {
            historyLocked = true
        } catch {
            if !error.isCancellation { failed = true }
        }
    }

    /// A drop developed just now resolves out of its pixels with a light haptic (a quick fade
    /// under Reduce Motion); one developed before shows the photo at once.
    private func present(_ image: UIImage, url: URL) async {
        let fresh = controls.isFreshlyDeveloped()
        playsDevelop = fresh && !reduceMotion
        withAnimation(fresh ? ClickMotion.subtleFade : nil) { developed = (image, url) }
        guard fresh else { return }
        ClickHaptics.impact(.light)
        try? await Task.sleep(for: .seconds(ClickDropDevelopEffect.duration))
        controls.didShowDevelop()
    }
}
