import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Click

@Suite("GIF messages (KLIPY)")
struct ChatGifTests {
    private let url = "https://static.klipy.com/ii/935d/14/af/JUYsGsrc.webp"
    private let metadata: [String: Any] = ["gif": ["provider": "klipy", "width": 498, "height": 280]]

    @Test("Only KLIPY static hosts over https count as GIF media")
    func hosts() {
        #expect(ChatGif.isKlipyMediaURL(url))
        #expect(ChatGif.isKlipyMediaURL("https://static2.klipy.com/a.gif"))
        #expect(!ChatGif.isKlipyMediaURL("http://static.klipy.com/a.gif"))
        #expect(!ChatGif.isKlipyMediaURL("https://static.klipy.com.evil.com/a.gif"))
        #expect(!ChatGif.isKlipyMediaURL("https://api.klipy.com/a.gif"))
        #expect(!ChatGif.isKlipyMediaURL("look \(url)"))
    }

    @Test("Parses the web contract: text row, KLIPY URL body, metadata.gif dimensions")
    func parse() throws {
        let gif = try #require(ChatGif.parse(messageType: "text", metadata: metadata, content: url))
        #expect(gif.url.absoluteString == url)
        #expect(gif.width == 498 && gif.height == 280)
        #expect(ChatGif.parse(messageType: "text", metadata: [:], content: url) == nil)
        #expect(ChatGif.parse(messageType: "text", metadata: metadata, content: "https://example.com/x.gif") == nil)
        #expect(ChatGif.parse(messageType: "text", metadata: metadata, content: "e2e2:abc") == nil)
        #expect(ChatGif.parse(messageType: "image", metadata: metadata, content: url) == nil)
    }

    @Test("Wire metadata carries dimensions only, never the URL")
    func wire() {
        let gif = ChatGif(url: URL(string: url)!, width: 10, height: 20)
        #expect(gif.wire["provider"] as? String == "klipy")
        #expect(gif.wire["width"] as? Int == 10)
        #expect(gif.wire.values.contains { ($0 as? String)?.contains("klipy.com") == true } == false)
    }

    @Test("A receipt update without content keeps the GIF on screen")
    func mergeKeepsGif() {
        var existing = ChatMessageItem(id: "m", chatID: "c", senderID: "u", senderName: "A", content: url, isOutgoing: false)
        existing.gif = ChatGif(url: URL(string: url)!, width: 1, height: 1)
        let update = ChatMessageItem(id: "m", chatID: "c", senderID: "u", senderName: "A", content: "", rawContent: "",
                                     deliveryStatus: .read, isOutgoing: false)
        #expect(ConversationModel.merged(existing: existing, update: update).gif == existing.gif)
    }

    @Test("Inbox previews and reply quotes say GIF, not the URL")
    @MainActor
    func labels() {
        let item = ConnectionItem(id: "c", userID: "u", connectionID: "c", displayName: "Ada", handle: "", initials: "AD",
                                  isOnline: false, lastActiveRelative: "", encounterLocation: "",
                                  lastMessage: InboxLastMessage(content: "e2e2:x", messageType: "text", isOutgoing: false, isRead: false))
        #expect(InboxFormatting.preview(for: item, decryptedText: url) == "GIF")
        var message = ChatMessageItem(id: "m", chatID: "c", senderID: "u", senderName: "A", content: url, isOutgoing: true)
        message.gif = ChatGif(url: URL(string: url)!, width: 1, height: 1)
        #expect(ConversationModel.quoteText(message) == "GIF")
    }

    @Test("Parses a KLIPY page, preferring WebP and the right size tier")
    func klipyPage() throws {
        let json = """
        {"result":true,"data":{"data":[{"id":8041071659142944,"slug":"hello-hi-662","title":"Hello","type":"gif","file":{
          "md":{"gif":{"url":"https://static.klipy.com/md.gif","width":498,"height":498,"size":1},
                "webp":{"url":"https://static.klipy.com/md.webp","width":498,"height":498,"size":1}},
          "sm":{"gif":{"url":"https://static.klipy.com/sm.gif","width":220,"height":220,"size":1}}}},
          {"id":2,"slug":"broken","file":{}}],
          "current_page":1,"per_page":24,"has_next":true}}
        """
        let page = try KlipyClient.parsePage(Data(json.utf8), requestedPage: 1)
        #expect(page.hasNext)
        #expect(page.items.count == 1)
        #expect(page.items[0].id == "8041071659142944")
        #expect(page.items[0].send.url.absoluteString == "https://static.klipy.com/md.webp")
        #expect(page.items[0].preview.url.absoluteString == "https://static.klipy.com/sm.gif")
    }

    @Test("customer_id is a stable hash, never the raw user ID")
    func customerID() {
        let id = KlipyClient.customerID(userID: "user-123")
        #expect(id == KlipyClient.customerID(userID: "user-123"))
        #expect(id.count == 32)
        #expect(!id.contains("user-123"))
    }

    @Test("Animated GIFs decode with every frame and are sent without re-encoding")
    func animatedDecode() async throws {
        let data = try Self.makeGIF(frames: 3)
        #expect(AnimatedImageDecoder.isGIF(data))
        #expect(AnimatedImageDecoder.isAnimated(data))
        let image = try #require(AnimatedImageDecoder.image(from: data, maxPixelSize: 64))
        #expect(image.images?.count == 3)
        #expect(AnimatedImageDecoder.image(from: data, maxPixelSize: 64, maxFrames: 2)?.images?.count == 2)

        let draft = try #require(await MediaDraftBuilder.image(from: data))
        #expect(draft.mimeType == "image/gif")
        #expect(draft.data == data)
    }

    private static func makeGIF(frames: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        for index in 0..<frames {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            let frame = renderer.image { context in
                UIColor(hue: CGFloat(index) / CGFloat(frames), saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            CGImageDestinationAddImage(destination, try #require(frame.cgImage), frameProperties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
