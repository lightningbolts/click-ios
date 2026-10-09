import Foundation
import Testing
@testable import Click

@Suite("Chat devices")
struct ChatDevicesTests {
    @Test("Reads /api/me/devices rows, skipping any without an ID")
    func parse() throws {
        let rows: [[String: Any]] = [
            ["device_id": "ios-1", "label": "iPhone", "created_at": "2026-10-01T10:00:00Z", "last_seen_at": "2026-10-09T08:30:00Z"],
            ["device_id": "web-1", "label": NSNull(), "created_at": "2026-09-20T10:00:00Z", "last_seen_at": NSNull()],
            ["label": "Ghost"],
        ]
        let devices = rows.compactMap(ChatRepository.ChatDevice.parse)
        #expect(devices.map(\.id) == ["ios-1", "web-1"])
        #expect(devices[0].label == "iPhone")
        #expect(devices[0].lastSeenAt != nil)
        #expect(devices[1].label == nil)
        #expect(devices[1].lastSeenAt == nil)
        #expect(devices[1].createdAt != nil)
    }

    @Test("A device's label picks its symbol", arguments: [
        ("iPhone", "iphone"), ("iPad", "ipad"), ("Chrome on Mac", "laptopcomputer"),
        ("Safari on iPhone", "iphone"), ("Web browser", "laptopcomputer"),
    ])
    func symbol(label: String, symbol: String) {
        #expect(DeviceApprovalSheet.symbol(for: label) == symbol)
    }
}
