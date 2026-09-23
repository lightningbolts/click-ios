import SwiftUI

/// The canonical avatar for people and generated group identities.
///
/// Renders the remote image through `ImagePipeline` (cached, downsampled off-main) and falls
/// back to initials on a quiet brand tint while loading or when no image exists. Decorative for
/// accessibility: the surrounding control is responsible for naming the person.
public struct AvatarView: View {
    public enum Presence: Sendable {
        case online
        case offline
    }

    private let url: URL?
    private let initials: String
    private let size: CGFloat
    private let presence: Presence?

    @State private var image: UIImage?

    public init(imageURL: String?, initials: String, size: CGFloat, presence: Presence? = nil) {
        let trimmed = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        self.url = url
        self.initials = initials
        self.size = size
        self.presence = presence
        // Seed from the memory cache so recycled rows never flash the fallback.
        self._image = State(initialValue: url.flatMap {
            ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: Self.pixelSize(for: size))
        })
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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

    private var fallback: some View {
        Circle()
            .fill(ClickColors.selectionTint)
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: max(10, size * 0.36), weight: .semibold))
                    .foregroundStyle(ClickColors.accentForeground)
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
