import Foundation
import Testing
@testable import Click

@Suite("Listening now")
struct ListeningNowTests {
    private func state(count: Int, me: Bool, names: [String]) -> ListeningNow {
        ListeningNow.parse([
            "count": count, "is_listening": me, "heartbeat_seconds": 360,
            "connections": names.map { ["user_id": $0.lowercased(), "name": $0] }
        ])
    }

    @Test("Summaries name connections only and count everyone else")
    func summaries() {
        #expect(state(count: 0, me: false, names: []).summary == nil)
        #expect(state(count: 1, me: true, names: []).summary == "You're listening here")
        #expect(state(count: 4, me: false, names: []).summary == "4 listening now")
        #expect(state(count: 1, me: false, names: ["Maya"]).summary == "Maya is listening")
        #expect(state(count: 3, me: true, names: ["Maya", "Sam"]).summary == "Maya and Sam are listening")
        #expect(state(count: 5, me: true, names: ["Maya"]).summary == "Maya and 3 others are listening")
        #expect(state(count: 2, me: false, names: ["Maya"]).summary == "Maya and 1 other are listening")
    }

    @Test("Heartbeat cadence never drops below a minute")
    func cadence() {
        #expect(ListeningNow.parse(["heartbeat_seconds": 5]).heartbeatSeconds == 60)
        #expect(ListeningNow.parse([:]).heartbeatSeconds == 360)
    }

    @Test("Reactions parse mine, reactors and ownership")
    func parsesReactions() {
        let state = ReactionsState.parse(["mine": "🔥", "is_owner": false,
                                          "reactions": [["user_id": "u1", "name": "Maya Chen", "emoji": "😂"]]])
        #expect(state.mine == "🔥")
        #expect(state.reactions.first?.emoji == "😂")
        #expect(!state.isOwner)
        #expect(ReactionsState.palette.count == 6)
    }

    @Test("The reconnect reminder opens the chat with that Click")
    func reconnectTapRoute() {
        let route = ClickNotificationCoordinator.tapRoute(for: ["type": "reconnect_nearby", "connection_id": "c1", "peer_user_id": "u1", "sender_name": "Maya"])
        #expect(route == .chat(chatID: nil, connectionID: "c1", senderUserID: "u1", senderName: "Maya"))
    }
}
