import CoreImage
import Foundation
import ImageIO
import UIKit

/// One Core Image context for every drop render: making a context costs far more than a render,
/// and a context is safe to share across threads.
enum ClickCIContext {
    private final class Box: @unchecked Sendable {
        let value = CIContext()
    }

    private nonisolated static let box = Box()
    nonisolated static var shared: CIContext { box.value }
}

/// The ten Click Drop "roll" looks, with the exact Core Image chain KMP uses on iOS
/// (`iosApp/SharedNative/ClickDisposableRollFilter.m`, names from `DisposableRollFilters.kt`).
enum ClickDropFilter: Int, CaseIterable, Identifiable, Sendable {
    case natural, warm, cool, vintage, dramatic, fade, noir, vibrant, golden, moody

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .natural: "Natural"
        case .warm: "Warm"
        case .cool: "Cool"
        case .vintage: "Vintage"
        case .dramatic: "Dramatic"
        case .fade: "Fade"
        case .noir: "Noir"
        case .vibrant: "Vibrant"
        case .golden: "Golden"
        case .moody: "Moody"
        }
    }

    /// An event recap's look for one drop: every look but Natural, picked by the drop's server
    /// seed so it's the same on every device (spec F1). The original is never modified.
    nonisolated static func recapLook(seed: Int) -> ClickDropFilter {
        let looks = allCases.filter { $0 != .natural }
        return looks[((seed % looks.count) + looks.count) % looks.count]
    }

    /// KMP caps live previews at 1280 px; sent photos use the chat image limit.
    nonisolated static let previewMaxDimension: CGFloat = 1280
    nonisolated static let sendMaxDimension: CGFloat = 2048

    nonisolated func apply(to input: CIImage) -> CIImage {
        switch self {
        case .natural: input
        case .warm: Self.temperature(input, target: 6200)
        case .cool: Self.temperature(input, target: 4200)
        case .vintage: Self.sepia(input, 0.82)
        case .dramatic: Self.colorControls(input, contrast: 1.45)
        case .fade: Self.colorControls(input, brightness: -0.35, saturation: 0.72)
        case .noir: CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: input])?.outputImage ?? input
        case .vibrant: Self.colorControls(input, saturation: 1.65)
        case .golden: Self.colorControls(Self.sepia(input, 0.45), saturation: 1.18)
        case .moody: Self.colorControls(Self.vignette(input, intensity: 0.85, radius: 1.35), contrast: 1.18)
        }
    }

    /// Oriented, downscaled, filtered JPEG (quality 0.88 like KMP). Nil when the data isn't an image.
    nonisolated func render(jpeg: Data, maxDimension: CGFloat) -> Data? {
        guard let output = filtered(jpeg, maxDimension: maxDimension) else { return nil }
        return ClickCIContext.shared.jpegRepresentation(of: output, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88])
    }

    /// The same look straight to an image for the screen (no JPEG round trip).
    nonisolated func renderImage(jpeg: Data, maxDimension: CGFloat) -> UIImage? {
        guard let output = filtered(jpeg, maxDimension: maxDimension),
              let cg = ClickCIContext.shared.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private nonisolated func filtered(_ jpeg: Data, maxDimension: CGFloat) -> CIImage? {
        guard var image = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else { return nil }
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let output = apply(to: image).cropped(to: image.extent)
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.origin.x, y: -output.extent.origin.y))
    }

    private nonisolated static func temperature(_ input: CIImage, target: CGFloat) -> CIImage {
        CIFilter(name: "CITemperatureAndTint", parameters: [
            kCIInputImageKey: input,
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: target, y: 0)
        ])?.outputImage ?? input
    }

    private nonisolated static func sepia(_ input: CIImage, _ intensity: CGFloat) -> CIImage {
        CIFilter(name: "CISepiaTone", parameters: [kCIInputImageKey: input, kCIInputIntensityKey: intensity])?.outputImage ?? input
    }

    private nonisolated static func vignette(_ input: CIImage, intensity: CGFloat, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIVignette", parameters: [kCIInputImageKey: input, kCIInputIntensityKey: intensity,
                                                  kCIInputRadiusKey: radius])?.outputImage ?? input
    }

    private nonisolated static func colorControls(_ input: CIImage, brightness: CGFloat = 0, saturation: CGFloat = 1, contrast: CGFloat = 1) -> CIImage {
        CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: input,
            kCIInputBrightnessKey: brightness,
            kCIInputSaturationKey: saturation,
            kCIInputContrastKey: contrast
        ])?.outputImage ?? input
    }
}
