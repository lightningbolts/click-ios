import SwiftUI

/// Pick a Click or group to send something to (share an event, forward a message). One list,
/// one search field, one sending state; the caller supplies what "send" means.
struct ChatTargetPicker: View {
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Chats to leave out (the one being forwarded from).
    var excludedChatIDs: Set<String> = []
    let send: (ConversationIdentity) async throws -> Void

    @State private var query = ""
    @State private var sending: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                let people = conversations.active.filter {
                    (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query))
                        && !excludedChatIDs.contains($0.chatID ?? $0.connectionID) && !excludedChatIDs.contains($0.connectionID)
                }
                let groups = conversations.groups.filter {
                    (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) && !excludedChatIDs.contains($0.chatID)
                }
                if !people.isEmpty {
                    Section("Clicks") {
                        ForEach(people) { item in
                            row(title: item.displayName, id: item.id,
                                avatar: AnyView(AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: 40))) {
                                ConversationIdentity(chatID: item.chatID ?? item.connectionID, connectionID: item.connectionID,
                                                     peerUserID: item.userID, peerDisplayName: item.displayName)
                            }
                        }
                    }
                }
                if !groups.isEmpty {
                    Section("Groups") {
                        ForEach(groups) { group in
                            row(title: group.name, id: group.id,
                                avatar: AnyView(GroupAvatarView(avatarURL: group.avatarURL, seed: group.chatID, initials: group.initials,
                                                                members: group.members, size: 40))) {
                                group.chatRoute.conversationIdentity
                            }
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Couldn't send", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func row(title: String, id: String, avatar: AnyView, identity: @escaping () -> ConversationIdentity) -> some View {
        Button {
            Task { await perform(identity(), id: id) }
        } label: {
            HStack(spacing: 12) {
                avatar
                Text(title).foregroundStyle(ClickColors.textPrimary)
                Spacer()
                if sending == id { ProgressView() }
            }
        }
        .disabled(sending != nil)
        .accessibilityHint("Sends to \(title)")
    }

    private func perform(_ identity: ConversationIdentity, id: String) async {
        sending = id
        defer { sending = nil }
        do {
            try await send(identity)
            ClickHaptics.success()
            dismiss()
        } catch {
            self.error = error.userFacingMessage
        }
    }
}
