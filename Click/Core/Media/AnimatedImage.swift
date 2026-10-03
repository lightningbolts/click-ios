import SwiftUI
import UIKit
import ImageIO

/// Decodes animated GIF / WebP data into an animated `UIImage` (SwiftUI's `Image` shows only the
/// first frame, so these are drawn with `AnimatedImageView`). Still images decode as usual.
enum AnimatedImageDecoder {
    /// Frames beyond this are dropped (keeps a long GIF from holding hundreds of bitmaps).
    static let defaultMaxFrames = 150

    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// GIF by signature (`GIF87a` / `GIF89a`), independent of any file extension or MIME label.
    static func isGIF(_ data: Data) -> Bool {
        data.count >= 6 && data.prefix(3) == Data("GIF".utf8)
    }

    /// An animated image when `data` has several frames, else a still one; every frame is
    /// downsampled so its longest side is at most `maxPixelSize`.
    static func image(from data: Data, maxPixelSize: CGFloat, maxFrames: Int = defaultMaxFrames) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let count = min(CGImageSourceGetCount(source), max(1, maxFrames))
        guard count > 0 else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ] as CFDictionary
        if count == 1 {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
        }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            frames.append(UIImage(cgImage: frame))
            duration += frameDelay(source, index)
        }
        guard !frames.isEmpty else { return nil }
        return frames.count == 1 ? frames[0] : UIImage.animatedImage(with: frames, duration: duration)
    }

    /// The frame's delay, treating near-zero delays as 0.1 s like browsers do.
    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let container = (properties?[kCGImagePropertyGIFDictionary] ?? properties?[kCGImagePropertyWebPDictionary]) as? [CFString: Any]
        let unclamped = container?[kCGImagePropertyGIFUnclampedDelayTime] ?? container?[kCGImagePropertyWebPUnclampedDelayTime]
        let clamped = container?[kCGImagePropertyGIFDelayTime] ?? container?[kCGImagePropertyWebPDelayTime]
        let delay = (unclamped as? Double).flatMap { $0 > 0 ? $0 : nil } ?? (clamped as? Double) ?? 0
        return delay < 0.011 ? 0.1 : delay
    }
}

/// Plays an animated `UIImage` (still images work too). Sized by SwiftUI; fills and clips.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.accessibilityIgnoresInvertColors = true
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = contentMode
        // Reduce Motion: hold the first frame.
        let shown = UIAccessibility.isReduceMotionEnabled ? (image.images?.first ?? image) : image
        if view.image !== shown { view.image = shown }
    }
}

/// A decoded still or animated image, drawn with the right view for each.
struct StillOrAnimatedImage: View {
    let image: UIImage

    var body: some View {
        if (image.images?.count ?? 0) > 1 {
            AnimatedImageView(image: image)
                .aspectRatio(image.size, contentMode: .fit)
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(image.size, contentMode: .fit)
        }
    }
}

/// A bounded memory cache of decoded images. `NSCache` is thread-safe; this wrapper says so to
/// the compiler, which can't see it (works the same on the Swift 6.0 and later toolchains).
final class DecodedImageMemory: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init(totalCostLimit: Int) {
        cache.totalCostLimit = totalCostLimit
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Loads KLIPY GIF media straight from the URL KLIPY returned (their terms forbid re-hosting),
/// with in-flight de-duplication and a bounded memory cache of decoded frames.
actor RemoteAnimatedImageLoader {
    static let shared = RemoteAnimatedImageLoader()

    private let session: URLSession
    /// Readable synchronously (`cached`) so a view shows its GIF on its first frame.
    private nonisolated let memory = DecodedImageMemory(totalCostLimit: 48 * 1024 * 1024)
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024,
                                   directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                       .appendingPathComponent("GIFMedia", isDirectory: true))
        config.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: config)
    }

    private nonisolated static func key(_ url: URL, _ maxPixelSize: CGFloat, _ maxFrames: Int) -> String {
        "\(url.absoluteString)#\(Int(maxPixelSize))#\(maxFrames)"
    }

    /// An already-decoded image, without waiting: lets a reused cell show its GIF immediately.
    nonisolated func cached(for url: URL, maxPixelSize: CGFloat, maxFrames: Int = AnimatedImageDecoder.defaultMaxFrames) -> UIImage? {
        memory.image(for: Self.key(url, maxPixelSize, maxFrames))
    }

    func image(for url: URL, maxPixelSize: CGFloat, maxFrames: Int = AnimatedImageDecoder.defaultMaxFrames) async -> UIImage? {
        let key = Self.key(url, maxPixelSize, maxFrames)
        if let hit = memory.image(for: key) { return hit }
        if let pending = inFlight[key] { return await pending.value }
        let session = self.session
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return AnimatedImageDecoder.image(from: data, maxPixelSize: maxPixelSize, maxFrames: maxFrames)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let frames = image.images ?? [image]
            let cost = frames.reduce(0) { $0 + ($1.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
            memory.insert(image, for: key, cost: cost)
        }
        return image
    }
}
