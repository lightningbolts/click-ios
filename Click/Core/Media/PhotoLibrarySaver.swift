import Foundation
import Photos

/// "Save to Photos" for decrypted chat images. Asks for add-only access (never full library).
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case denied

        var errorDescription: String? {
            "Allow Click to add photos in Settings to save this image."
        }
    }

    static func saveImage(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}
