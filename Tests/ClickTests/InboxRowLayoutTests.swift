import SwiftUI
import Testing
import UIKit
@testable import Click

@Suite("Inbox row layout")
@MainActor
struct InboxRowLayoutTests {
    private func height(_ view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: 390))
        return host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)).height
    }

    @Test("Direct, group and hub rows are the same height, whatever the preview length")
    func rowsShareOneHeight() {
        let dm = ConnectionItem(id: "c1", userID: "u1", connectionID: "c1", displayName: "Priya Raman", handle: "",
                                initials: "PR", isOnline: false, lastActiveRelative: "", encounterLocation: "",
                                lastActivityAt: .now, unreadCount: 2)
        let group = CliqueItem(id: "g1", chatID: "cg", name: "Climbing crew", memberCount: 4, lastActivityAt: .now)
        let hub = JoinedHub(hubID: "h1", name: "Cal Anderson", category: nil, eventBeaconID: nil, joinedAt: .now,
                            lastMessage: "Anyone near the fountain?", lastSenderName: "Lena", lastActivityAt: .now)

        let direct = height(ConversationRow(
            item: dm,
            preview: "A long preview that definitely wraps onto a second line because it keeps going and going",
            onOpen: {}, onProfile: {}
        ))
        let groupRow = height(GroupInboxRow(group: group, preview: "Short", avatarMembers: [], onOpen: {}))
        let hubRow = height(HubInboxRow(hub: hub, onOpen: {}))

        #expect(direct > 0)
        #expect(abs(direct - groupRow) < 0.5)
        #expect(abs(direct - hubRow) < 0.5)
    }
}
