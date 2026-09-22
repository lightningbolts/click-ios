import Foundation
import UIKit

/// Canonical avatar normalization, compression, and upload service.
public final class AvatarService: Sendable {
    public static let shared = AvatarService()

    private let maxDimension: CGFloat = 1200.0
    private let maxBytes: Int = 2_000_000

    public init() {}

    public struct AvatarUploadResponse: Decodable, Sendable {
        public let image: String
        public let user: [String: AnyCodable]?
    }

    public func prepareImageData(_ imageData: Data) throws -> Data {
        guard let image = UIImage(data: imageData) else {
            throw APIError.validation(code: "invalid_image", message: "Cannot decode image data.")
        }

        // Normalize orientation by redrawing
        let size = image.size
        let targetSize: CGSize
        if size.width > maxDimension || size.height > maxDimension {
            let ratio = min(maxDimension / size.width, maxDimension / size.height)
            targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        } else {
            targetSize = size
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let normalizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Compress to JPEG <= 2 MB
        var quality: CGFloat = 0.85
        guard var jpegData = normalizedImage.jpegData(compressionQuality: quality) else {
            throw APIError.validation(code: "compression_failed", message: "Failed to compress image.")
        }

        while jpegData.count > maxBytes && quality > 0.3 {
            quality -= 0.15
            if let nextData = normalizedImage.jpegData(compressionQuality: quality) {
                jpegData = nextData
            }
        }

        guard jpegData.count <= maxBytes else {
            throw APIError.validation(code: "file_too_large", message: "Image exceeds maximum allowed size of 2 MB.")
        }

        return jpegData
    }

    /// Normalizes orientation, downsamples off-main, ensures <= 2 MB contract, and uploads via ClickAPIClient.
    public func uploadAvatar(imageData: Data, client: ClickAPIClient) async throws -> String {
        // Off-main processing
        let processedData: Data = try await Task.detached(priority: .userInitiated) { [self] in
            try self.prepareImageData(imageData)
        }.value

        let base64 = processedData.base64EncodedString()
        let payload: [String: Any] = [
            "file_b64": base64,
            "mime_type": "image/jpeg"
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let request = APIRequest(
            path: "/api/user/avatar",
            method: .post,
            body: body,
            requiresAuth: true
        )

        let response: AvatarUploadResponse = try await client.execute(request)
        return response.image
    }
}
