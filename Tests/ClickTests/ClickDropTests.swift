import CoreImage
import Foundation
import Testing
import UIKit
@testable import Click

@Suite("Click Drop")
struct ClickDropTests {
    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.9)!
    }

    @Test("Ten looks in KMP order")
    func filterOrder() {
        #expect(ClickDropFilter.allCases.map(\.name) == ["Natural", "Warm", "Cool", "Vintage", "Dramatic", "Fade", "Noir", "Vibrant", "Golden", "Moody"])
    }

    @Test("Previews are capped at 1280 px and keep the aspect ratio")
    func previewCap() throws {
        let data = try #require(ClickDropFilter.noir.render(jpeg: jpeg(width: 2000, height: 1000), maxDimension: ClickDropFilter.previewMaxDimension))
        let image = try #require(UIImage(data: data))
        #expect(Int(image.size.width) == 1280)
        #expect(Int(image.size.height) == 640)
    }

    @Test("Every look renders; Noir is grayscale")
    func everyLookRenders() throws {
        let source = jpeg(width: 64, height: 64)
        for look in ClickDropFilter.allCases {
            #expect(look.render(jpeg: source, maxDimension: 64) != nil)
        }
        let rendered = try #require(ClickDropFilter.noir.render(jpeg: source, maxDimension: 64))
        let noir = try #require(CIImage(data: rendered))
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(noir, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 32, y: 32, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        #expect(abs(Int(pixel[0]) - Int(pixel[1])) <= 3 && abs(Int(pixel[1]) - Int(pixel[2])) <= 3)
    }

    @Test("A Drop carries the encounter only for its connection while the window is open")
    func sessionEncounter() {
        let session = ClickDropSession(connectionID: "c1", encounterID: "e1", endsAt: Date(timeIntervalSince1970: 1000))
        #expect(session.encounterID(for: "c1", now: Date(timeIntervalSince1970: 999)) == "e1")
        #expect(session.encounterID(for: "c2", now: Date(timeIntervalSince1970: 999)) == nil)
        #expect(session.encounterID(for: "c1", now: Date(timeIntervalSince1970: 1001)) == nil)
    }

    @Test("Garbage data doesn't render")
    func garbage() {
        #expect(ClickDropFilter.warm.render(jpeg: Data([1, 2, 3]), maxDimension: 100) == nil)
    }
}
