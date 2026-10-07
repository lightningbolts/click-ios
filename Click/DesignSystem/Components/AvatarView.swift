import SwiftUI

/// The canonical avatar for people and generated group identities.
///
/// Renders the remote image through `ImagePipeline` (cached, downsampled off-main) and falls
/// back to initials on a color derived from the person's or group's stable ID — the same color
/// the Android client shows. Decorative for accessibility: the surrounding control names the person.
public struct AvatarView: View {
    public enum Presence: Sendable {
        case online
        case offline
    }

    private let url: URL?
    private let seed: String
    private let initials: String
    private let size: CGFloat
    private let presence: Presence?
    private let isCore: Bool

    @State private var image: UIImage?

    /// - Parameters:
    ///   - seed: the stable user or group ID that selects the fallback color.
    ///   - isCore: a Core Click: the gold-to-purple ring, drawn inside `size` so layouts never shift.
    public init(imageURL: String?, seed: String, initials: String, size: CGFloat, presence: Presence? = nil, isCore: Bool = false) {
        let trimmed = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        self.url = url
        self.seed = seed
        self.initials = initials
        self.size = size
        self.presence = presence
        self.isCore = isCore
        // Seed from memory (or disk after a cold start) so rows never flash the fallback.
        self._image = State(initialValue: url.flatMap {
            ImagePipeline.shared.firstFrameImage(for: $0, maxPixelSize: Self.pixelSize(for: size))
        })
    }

    public var body: some View {
        let ring = isCore ? Self.ringWidth(for: size) : 0
        let face = size - 2 * (isCore ? ring + Self.ringGap(for: size) : 0)
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback(size: face)
            }
        }
        .frame(width: face, height: face)
        .clipShape(Circle())
        .frame(width: size, height: size)
        .overlay {
            if isCore {
                Circle().strokeBorder(ClickColors.coreRing, lineWidth: ring)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let presence {
                presenceDot(presence)
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let loaded = await ImagePipeline.shared.image(for: url, maxPixelSize: Self.pixelSize(for: size))
            if !Task.isCancelled {
                image = loaded
            }
        }
    }

    /// Decode at 3x so one cache entry serves every device scale.
    private static func pixelSize(for size: CGFloat) -> CGFloat { size * 3 }

    /// Decodes these avatars into memory ahead of display at `size`.
    static func prefetch(_ urls: [String?], size: CGFloat) {
        ImagePipeline.shared.prefetch(urls.compactMap { $0?.nonEmptyTrimmed.flatMap(URL.init(string:)) },
                                      maxPixelSize: pixelSize(for: size))
    }

    private static func ringWidth(for size: CGFloat) -> CGFloat { max(2, (size * 0.045).rounded()) }
    private static func ringGap(for size: CGFloat) -> CGFloat { max(1.5, (size * 0.03).rounded()) }

    private func fallback(size: CGFloat) -> some View {
        Circle()
            .fill(ClickColors.GeneratedContent.avatarColor(for: seed))
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: max(10, size * 0.36), weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(size * 0.12)
            }
    }

    private func presenceDot(_ presence: Presence) -> some View {
        let diameter = max(10, size * 0.22)
        return Circle()
            .fill(presence == .online ? ClickColors.online : ClickColors.offline)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().stroke(ClickColors.background, lineWidth: 2)
            }
    }
}

extension AvatarView.Presence {
    /// Maps a possibly-unknown presence into a displayable state; unknown presence shows no dot.
    public init?(isOnline: Bool, known: Bool) {
        guard known else { return nil }
        self = isOnline ? .online : .offline
    }
}
