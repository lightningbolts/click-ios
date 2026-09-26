import SwiftUI

/// Pick Clicks and groups to send something to (forward a message, share an event): tap rows to
/// select (up to `maxTargets`), see what's being sent, then press Send. Nothing goes out on a
/// row tap. The caller supplies what "send" means for one target.
struct ChatTargetPicker: View {
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Chats to leave out (the one being forwarded from).
    var excludedChatIDs: Set<String> = []
    /// What's being sent, shown above the list (a message excerpt, an event title).
    var preview: String?
    var previewSymbol = "text.bubble"
    let send: (ConversationIdentity) async throws -> Void

    /// Forwarding to many chats at once is how spam spreads; five matches WhatsApp.
    static let maxTargets = 5

    private struct Target: Identifiable {
        let id: String
        let title: String
        let identity: ConversationIdentity
    }

    @State private var query = ""
    @State private var selected: [Target] = []
    @State private var isSending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let preview {
                    Section {
                        Label {
                            Text(preview).lineLimit(3).foregroundStyle(ClickColors.textSecondary)
                        } icon: {
                            Image(systemName: previewSymbol).foregroundStyle(ClickColors.accentForeground)
                        }
                    }
                }
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
                            row(Target(id: item.id, title: item.displayName,
                                       identity: ConversationIdentity(chatID: item.chatID ?? item.connectionID, connectionID: item.connectionID,
                                                                      peerUserID: item.userID, peerDisplayName: item.displayName))) {
                                AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: 40)
                            }
                        }
                    }
                }
                if !groups.isEmpty {
                    Section("Groups") {
                        ForEach(groups) { group in
                            row(Target(id: group.id, title: group.name, identity: group.chatRoute.conversationIdentity)) {
                                GroupAvatarView(avatarURL: group.avatarURL, seed: group.chatID, initials: group.initials,
                                                members: group.members, size: 40)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { sendBar }
            .interactiveDismissDisabled(isSending)
            .alert("Couldn't send", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func row(_ target: Target, @ViewBuilder avatar: () -> some View) -> some View {
        let isSelected = selected.contains { $0.id == target.id }
        let isFull = selected.count >= Self.maxTargets
        return Button {
            toggle(target)
        } label: {
            HStack(spacing: 12) {
                avatar()
                Text(target.title).foregroundStyle(ClickColors.textPrimary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? ClickColors.accentForeground : ClickColors.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSending || (isFull && !isSelected))
        .opacity(isFull && !isSelected ? 0.45 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ target: Target) {
        ClickHaptics.selection()
        if let index = selected.firstIndex(where: { $0.id == target.id }) {
            selected.remove(at: index)
        } else if selected.count < Self.maxTargets {
            selected.append(target)
        }
    }

    @ViewBuilder
    private var sendBar: some View {
        if !selected.isEmpty {
            HStack(spacing: 12) {
                Text(ListFormatter.localizedString(byJoining: selected.map(\.title)))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await sendAll() }
                } label: {
                    if isSending {
                        ProgressView().frame(minWidth: 72)
                    } else {
                        Label("Send", systemImage: "paperplane.fill").frame(minWidth: 72)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
                .disabled(isSending)
                .accessibilityLabel("Send to \(selected.count) \(selected.count == 1 ? "chat" : "chats")")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Sends to each selected chat in order; failures stay selected so Send retries only them.
    private func sendAll() async {
        isSending = true
        defer { isSending = false }
        var failed: [Target] = []
        var lastError: Error?
        for target in selected {
            do {
                try await send(target.identity)
            } catch {
                failed.append(target)
                lastError = error
            }
        }
        if failed.isEmpty {
            ClickHaptics.success()
            dismiss()
        } else {
            ClickHaptics.warning()
            let sentCount = selected.count - failed.count
            selected = failed
            let names = ListFormatter.localizedString(byJoining: failed.map(\.title))
            error = (sentCount > 0 ? "Sent to \(sentCount), but not to \(names). " : "Not sent to \(names). ")
                + (lastError?.userFacingMessage ?? "")
        }
    }
}
