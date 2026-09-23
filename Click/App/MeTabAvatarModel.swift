import SwiftUI
import UIKit
import Observation

/// Supplies the signed-in user's profile photo as the native Me tab image.
///
/// SwiftUI tab items ignore frame/clip modifiers, so the photo is pre-rendered into a small
/// circular original-rendering `UIImage`. Only the Me tab's label changes when the image
/// changes; the `TabView` and its native chrome are never rebuilt. A `nil` image means the
/// caller shows the person-circle fallback symbol.
@Observable
@MainActor
public final class MeTabAvatarModel {
    public private(set) var image: UIImage?

    private var avatarURL: URL?
    private var loadTask: Task<Void, Never>?

    /// Tab bar glyphs are ~25–28pt; a 28pt circle matches the optical weight of SF Symbols.
    static let diameter: CGFloat = 28

    public init() {}

    /// Updates the photo. Repeated calls with the same URL are no-ops, so callers may forward
    /// every profile refresh without triggering reloads.
    public func update(avatarURL rawValue: String?) {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        guard url != avatarURL else { return }
        avatarURL = url
        loadTask?.cancel()

        guard let url else {
            image = nil
            return
        }

        loadTask = Task { [weak self] in
            let pixelSize = Self.diameter * 3
            guard
                let photo = await ImagePipeline.shared.image(for: url, maxPixelSize: pixelSize),
                !Task.isCancelled,
                let self
            else { return }
            self.image = Self.circularTabImage(photo)
        }
    }

    /// Clips the photo to a circle and marks it original so the tab bar does not template-tint it.
    private static func circularTabImage(_ photo: UIImage) -> UIImage {
        let rect = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
        let rendered = UIGraphicsImageRenderer(size: rect.size).image { _ in
            UIBezierPath(ovalIn: rect).addClip()
            photo.draw(in: aspectFill(photo.size, in: rect))
        }
        return rendered.withRenderingMode(.alwaysOriginal)
    }

    private static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.midX - fitted.width / 2,
            y: rect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
