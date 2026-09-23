import Testing
import Foundation
import UIKit
@testable import Click

@Suite("Main shell per-tab navigation")
@MainActor
struct ShellNavigationTests {
    @Test("Each externally delivered route resolves onto its canonical tab")
    func canonicalTabs() {
        let expectations: [(AppRoute, MainTab)] = [
            (.chat(DirectChatRoute(peerUserID: "usr_1", peerDisplayName: "Ada")), .connections),
            (.userProfile(userID: "usr_1", connectionID: nil), .connections),
            (.groupProfile(chatID: "chat_1"), .connections),
            (.event(beaconID: "bcn_1"), .map),
            (.beacon(beaconID: "bcn_2"), .map),
            (.hub(hubID: "hub_1"), .map),
            (.myQR, .addClick),
            (.scanQR, .addClick),
            (.tapConnect, .addClick),
            (.connectionInvocation(ConnectionInvocation(userID: "usr_2")), .addClick),
            (.savedEvents, .settings)
        ]

        for (route, tab) in expectations {
            let router = AppRouter()
            router.resolveRoute(route)
            #expect(router.selectedTab == tab)
            #expect(router[path: tab] == [route])
        }
    }

    @Test("In-app navigation pushes onto the selected tab only")
    func navigateUsesSelectedTab() {
        let router = AppRouter()
        router.selectedTab = .settings
        router.navigate(to: .savedEvents)
        router.navigate(to: .event(beaconID: "bcn_saved"))

        #expect(router.settingsPath == [.savedEvents, .event(beaconID: "bcn_saved")])
        #expect(router.mapPath.isEmpty)
        #expect(router.homePath.isEmpty)
    }

    @Test("Switching tabs preserves stacks; reselecting the active tab pops to root")
    func reselectPopsToRoot() {
        let router = AppRouter()
        router.selectTab(.connections)
        router.navigate(to: .userProfile(userID: "usr_1", connectionID: "conn_1"))
        router.selectTab(.map)
        router.navigate(to: .hub(hubID: "hub_1"))

        router.selectTab(.connections)
        #expect(router.connectionsPath.count == 1)
        #expect(router.mapPath.count == 1)

        router.selectTab(.connections)
        #expect(router.connectionsPath.isEmpty)
        #expect(router.mapPath.count == 1)
    }
}

@Suite("Image pipeline")
struct ImagePipelineTests {
    @Test("Downsamples to the requested pixel size and serves repeats from memory")
    func downsamplesAndCaches() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-pipeline-\(UUID().uuidString).png")
        try #require(source.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = ImagePipeline()
        #expect(pipeline.cachedImage(for: url, maxPixelSize: 60) == nil)

        let image = try #require(await pipeline.image(for: url, maxPixelSize: 60))
        let cgImage = try #require(image.cgImage)
        #expect(max(cgImage.width, cgImage.height) == 60)
        #expect(pipeline.cachedImage(for: url, maxPixelSize: 60) === image)
    }

    @Test("Undecodable data yields nil rather than a broken image")
    func undecodableDataReturnsNil() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-pipeline-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await ImagePipeline().image(for: url, maxPixelSize: 60) == nil)
    }
}
