import UIKit
import ImageIO

/// Loads public remote images (profile avatars) with in-flight deduplication, off-main
/// downsampling to the display size, and a bounded memory cache.
///
/// Never route decrypted private chat media through this pipeline or its shared URL cache;
/// private content belongs in a separate media vault (spec §79).
public actor ImagePipeline {
    public static let shared = ImagePipeline()

    private let session: URLSession
    private let memory = MemoryCache()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    public init(session: URLSession = ImagePipeline.makeSession()) {
        self.session = session
    }

    /// Public images only (avatars, event covers): a dedicated 256 MB disk cache that honours
    /// HTTP caching, so repeat launches serve images from disk and unchanged images revalidate
    /// with a bodyless 304 instead of re-downloading (less Supabase egress).
    public static func makeSession() -> URLSession {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PublicImages", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, directory: directory)
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }

    /// Synchronous memory-cache lookup so views can render a cached image on their first frame.
    public nonisolated func cachedImage(for url: URL, maxPixelSize: CGFloat) -> UIImage? {
        memory.image(forKey: Self.key(url, maxPixelSize))
    }

    /// Returns the image downsampled so its longest side is at most `maxPixelSize` pixels,
    /// or `nil` if it could not be loaded or decoded.
    public func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = Self.key(url, maxPixelSize)
        if let cached = memory.image(forKey: key) { return cached }
        if let pending = inFlight[key] { return await pending.value }

        let session = self.session
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard
                let (data, response) = try? await session.data(from: url),
                (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return Self.downsample(data, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.insert(image, forKey: key) }
        return image
    }

    private nonisolated static func key(_ url: URL, _ maxPixelSize: CGFloat) -> String {
        "\(url.absoluteString)#\(Int(maxPixelSize.rounded(.up)))"
    }

    private nonisolated static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// `NSCache` is documented as thread-safe, which is what makes the unchecked conformance sound
    /// and lets `cachedImage` answer synchronously from any isolation domain.
    private final class MemoryCache: @unchecked Sendable {
        private let cache: NSCache<NSString, UIImage> = {
            let cache = NSCache<NSString, UIImage>()
            cache.totalCostLimit = 32 * 1024 * 1024
            return cache
        }()

        func image(forKey key: String) -> UIImage? {
            cache.object(forKey: key as NSString)
        }

        func insert(_ image: UIImage, forKey key: String) {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
    }
}
