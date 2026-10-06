import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Click

@Suite("Click Flyer")
struct ClickFlyerTests {
    @Test("The picture's frame keeps its shape within the format's range, never taller than the cap")
    func photoFrame() {
        let story = FlyerFormat.story.metrics
        #expect(story.photoFrame(for: CGSize(width: 1600, height: 900)) == CGSize(width: 260, height: 146))
        // Square posters stay square-ish; tall ones are capped.
        #expect(story.photoFrame(for: CGSize(width: 1000, height: 1000)).height == 250)
        #expect(story.photoFrame(for: CGSize(width: 800, height: 1600)).height == 250)
        // No picture: the generated art at the format's own shape.
        #expect(story.photoFrame(for: nil) == CGSize(width: 260, height: 163))
        let post = FlyerFormat.post.metrics
        #expect(post.photoFrame(for: CGSize(width: 1000, height: 1000)).height == 165)
        #expect(post.photoFrame(for: CGSize(width: 3000, height: 1000)) == CGSize(width: 280, height: 117))
    }

    @Test("A picture near its frame's shape fills it; a poster far from it is shown whole")
    func fillOrFit() {
        #expect(FlyerMetrics.fills(CGSize(width: 1600, height: 1200), frame: CGSize(width: 280, height: 165)))
        #expect(!FlyerMetrics.fills(CGSize(width: 1000, height: 1000), frame: CGSize(width: 280, height: 165)))
        #expect(FlyerMetrics.fills(CGSize(width: 1000, height: 1000), frame: CGSize(width: 260, height: 250)))
    }

    @Test("The date tile's accent is deep enough for white; a grey picture falls back to Click violet")
    func accent() {
        var saturation: CGFloat = 0, brightness: CGFloat = 0, hue: CGFloat = 0, alpha: CGFloat = 0
        FlyerArt.deepened(UIColor(red: 0.6, green: 0.8, blue: 1, alpha: 1)).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #expect(saturation >= 0.6 && brightness <= 0.7)
        #expect(FlyerArt.deepened(.gray) == UIColor(hex: "#7C3AED"))
    }

    @Test("Every format renders at 1080 px wide, with and without a picture")
    @MainActor
    func renders() throws {
        let pictures: [(String, UIImage?)] = [("landscape", Self.landscape()), ("poster", Self.poster()), ("plain", nil)]
        for (name, picture) in pictures {
            for format in FlyerFormat.allCases {
                let image = try #require(FlyerCanvas.render(format: format, content: Self.content, art: FlyerArt(seed: "e1", picture: picture)))
                #expect(image.size == format.size)
                #expect(image.scale == 3)
                Self.dump(image, name: "\(format.rawValue)-\(name)")
            }
        }
    }

    // MARK: - Fixtures

    private static let content = FlyerContent(
        title: "Sunset Run Club on the Burke-Gilman",
        host: "Hosted by Kairui Cheng",
        month: "SEP",
        day: "27",
        when: "Sat · 6:30 PM",
        place: "Burke-Gilman Trail, Seattle",
        link: URL(string: "https://joinclick.co/e/7f1c2a43b-6f32-41e5-9010-896ce503fc45")!
    )

    /// A photo-like landscape: sky, water, a treeline.
    private static func landscape() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 880)).image { context in
            let cg = context.cgContext
            let sky = CGGradient(colorsSpace: nil, colors: [UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1).cgColor,
                                                           UIColor(red: 0.62, green: 0.8, blue: 0.97, alpha: 1).cgColor] as CFArray, locations: nil)!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: 560), options: [])
            UIColor(red: 0.12, green: 0.3, blue: 0.5, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 560, width: 1200, height: 320))
            UIColor(red: 0.1, green: 0.28, blue: 0.14, alpha: 1).setFill()
            for index in 0..<24 {
                let x = CGFloat(index) * 52
                cg.move(to: CGPoint(x: x, y: 700))
                cg.addLine(to: CGPoint(x: x + 26, y: 520 + CGFloat(index % 4) * 25))
                cg.addLine(to: CGPoint(x: x + 52, y: 700))
                cg.fillPath()
            }
        }
    }

    /// A square text poster, the kind that must never be cropped.
    private static func poster() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000)).image { context in
            UIColor(red: 0.27, green: 0.1, blue: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
            let style = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 150, weight: .black),
                         .foregroundColor: UIColor(red: 0.85, green: 0.78, blue: 0.55, alpha: 1)]
            ("TEAM\nTUESDAY\nMEETUPS" as NSString).draw(at: CGPoint(x: 50, y: 60), withAttributes: style)
        }
    }

    /// Logs a small JPEG as known issues (shown in the CI log without failing), for checking the layout.
    private static func dump(_ image: UIImage, name: String) {
        let small = UIGraphicsImageRenderer(size: image.size, format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }())
            .image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let data = small.jpegData(compressionQuality: 0.6) else { return }
        let encoded = Array(data.base64EncodedString())
        var chunk = 0
        for start in stride(from: 0, to: encoded.count, by: 4000) {
            let part = String(encoded[start..<min(start + 4000, encoded.count)])
            withKnownIssue { Issue.record(Comment(rawValue: "FLYER_SNAPSHOT \(name) \(chunk) \(part)")) }
            chunk += 1
        }
    }
}
