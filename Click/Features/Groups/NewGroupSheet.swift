import SwiftUI

/// "New verified group" (prototype): pick Clicks, create on the server, initialize E2EE v2
/// when every member can hold it, then open the group chat. Used from Clicks (+) and Add Click.
struct NewGroupSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        GroupMemberPickerSheet(
            title: "New verified group",
            actionTitle: isCreating ? "Creating…" : "Create",
            candidates: conversations.active.filter { !$0.userID.isEmpty && !$0.connectionID.isEmpty },
            asksForName: true,
            explanation: "Pick friends who are all connected to each other. Eligibility is verified on the server.",
            onDone: { name, ids in Task { await create(name: name, memberIDs: ids) } }
        )
        .interactiveDismissDisabled(isCreating)
        .disabled(isCreating)
        .alert("Couldn't create the group", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func create(name: String, memberIDs: [String]) async {
        guard let userID = env.session.currentSession?.userId, !memberIDs.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        var connectionIDs: [String: String] = [:]
        var firstNames: [String] = []
        for item in conversations.active where memberIDs.contains(item.userID) {
            connectionIDs[item.userID] = item.connectionID
            firstNames.append(item.displayName.split(separator: " ").first.map(String.init) ?? item.displayName)
        }
        let groupName = name.nonEmptyTrimmed ?? firstNames.sorted().joined(separator: ", ")
        do {
            let groupID = try await env.groups.create(creatorID: userID, connectionIDs: connectionIDs, name: groupName)
            await conversations.refresh()
            guard let group = conversations.groups.first(where: { $0.id == groupID }) else {
                error = "The group was created but couldn't be loaded yet. Pull to refresh Groups."
                return
            }
            _ = try? await env.chat.reconcileMembershipEpoch(chatID: group.chatID, participantUserIDs: group.members.map(\.userID))
            dismiss()
            env.router.selectTab(.connections)
            env.router.navigate(to: .groupChat(group.chatRoute))
        } catch {
            self.error = error.userFacingMessage
        }
    }
}
